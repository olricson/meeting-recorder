import AVFoundation
import CoreGraphics
import Foundation
import MeetingRecorderShared

public actor RecorderCoordinator {
    private let paths: RecorderPaths
    private let configurations: ConfigurationStore
    private let states: StateStore
    private let lock: ProcessLock
    private let logger: FileLogger
    private var state: RecorderState
    private var capture: MeetingCaptureSession?
    private var lastActivity = Date()

    public init(paths: RecorderPaths = RecorderPaths()) throws {
        self.paths = paths
        try paths.createBaseDirectories()
        self.configurations = ConfigurationStore(paths: paths)
        self.states = StateStore(url: paths.stateFile)
        self.lock = ProcessLock(url: paths.lockFile)
        self.logger = FileLogger(fileURL: paths.logFile)
        self.state = states.load()
    }

    public func bootstrap() async {
        guard state.phase == .starting || state.phase == .recording || state.phase == .finalizing else { return }
        if let path = state.temporaryOutputPath {
            let recovered = await RecordingFileManager.recoverAbandonedRecording(at: URL(fileURLWithPath: path))
            state.phase = recovered == nil ? .failed : .idle
            state.finalOutputPath = recovered?.path
            if let sourcesPath = state.temporarySourcesPath {
                state.finalSourcesPath = await RecordingFileManager.recoverAbandonedRecording(
                    at: URL(fileURLWithPath: sourcesPath),
                    expectedAudioTracks: 2
                )?.path
            }
            state.lastError = recovered == nil
                ? "The previous recorder exited unexpectedly; its temporary file was not playable and was preserved with a .failed name."
                : nil
            state.warning = recovered == nil ? state.lastError : "Recovered an interrupted recording."
        } else {
            state.phase = .failed
            state.lastError = "The previous recorder exited unexpectedly without a temporary output path."
        }
        state.processID = nil
        try? states.save(state)
    }

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        lastActivity = Date()
        guard request.version == 1 else {
            return IPCResponse(requestID: request.requestID, success: false, message: "Unsupported IPC version \(request.version).")
        }
        do {
            switch request.command {
            case .setup:
                return try await setup(requestID: request.requestID)
            case .list:
                let snapshot = try await ShareableContentService.snapshot()
                return IPCResponse(requestID: request.requestID, success: true, message: "Shareable content listed.", content: snapshot)
            case .start(let selector):
                let state = try await start(selector: selector)
                return IPCResponse(requestID: request.requestID, success: true, message: startMessage(state), state: state)
            case .stop:
                let state = try await stop()
                let sources = state.finalSourcesPath.map { "\nSource tracks: \($0)" } ?? ""
                return IPCResponse(
                    requestID: request.requestID,
                    success: true,
                    message: "Saved \(state.finalOutputPath ?? "recording")\(sources)",
                    state: state
                )
            case .status:
                return IPCResponse(requestID: request.requestID, success: true, message: statusMessage(), state: state)
            case .configGetOutputDirectory:
                let configuration = try configurations.load()
                return IPCResponse(requestID: request.requestID, success: true, message: configuration.outputDirectory, outputDirectory: configuration.outputDirectory)
            case .configSetOutputDirectory(let value):
                let configuration = try configurations.setOutputDirectory(value)
                return IPCResponse(requestID: request.requestID, success: true, message: "Output directory set to \(configuration.outputDirectory)", outputDirectory: configuration.outputDirectory)
            }
        } catch {
            logger.log(.error, "Command failed: \(error.localizedDescription)")
            return IPCResponse(requestID: request.requestID, success: false, message: error.localizedDescription, state: state)
        }
    }

    public func stopForLifecycleEvent(_ reason: String) async {
        guard capture != nil else { return }
        logger.log(.warning, "Stopping because \(reason).")
        state.warning = "Recording stopped because \(reason)."
        _ = try? await stop()
    }

    public func selectedApplicationPID() -> Int32? { state.applicationProcessID }

    public func shouldExitAfterIdle(seconds: TimeInterval) -> Bool {
        capture == nil && Date().timeIntervalSince(lastActivity) >= seconds
    }

    private func setup(requestID: UUID) async throws -> IPCResponse {
        try paths.createBaseDirectories()
        _ = try configurations.load()
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphoneGranted: Bool
        switch microphoneStatus {
        case .authorized:
            microphoneGranted = true
        case .notDetermined:
            microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            microphoneGranted = false
        }
        guard microphoneGranted else {
            throw MeetingRecorderError.permissionDenied(
                "Microphone access is denied. Enable MeetingRecorder in System Settings > Privacy & Security > Microphone."
            )
        }
        do {
            _ = try await ShareableContentService.snapshot()
        } catch {
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            throw MeetingRecorderError.permissionDenied(
                "Screen & System Audio Recording access is not ready. Grant MeetingRecorder access in System Settings, quit the app if requested, then run setup again."
            )
        }
        let expectedBundleID = "com.olivier.meetingrecorder"
        let signing = SigningIdentityInspector.inspect()
        guard signing?.identifier == expectedBundleID else {
            throw MeetingRecorderError.unavailable(
                "The installed app does not have the expected signed identifier \(expectedBundleID). Rebuild and install the signed app bundle."
            )
        }
        let signer = signing?.certificateName ?? "unknown signer"
        let expectedLocation = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/MeetingRecorder.app").standardizedFileURL.path
        let locationWarning = Bundle.main.bundleURL.standardizedFileURL.path == expectedLocation
            ? ""
            : " Warning: the app is running from \(Bundle.main.bundleURL.path), not \(expectedLocation)."
        let message = "Setup complete for \(expectedBundleID), signed by \(signer). Permissions are local to this Mac.\(locationWarning)"
        return IPCResponse(requestID: requestID, success: true, message: message, state: state)
    }

    private func start(selector: SourceSelector) async throws -> RecorderState {
        guard capture == nil, state.phase != .starting, state.phase != .recording, state.phase != .finalizing else {
            throw MeetingRecorderError.alreadyRecording
        }
        guard try lock.tryLock() else { throw MeetingRecorderError.alreadyRecording }
        do {
            let configuration = try configurations.load()
            let outputDirectory = paths.expandPath(configuration.outputDirectory)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
                throw MeetingRecorderError.io("Output directory is not writable or is unavailable: \(outputDirectory.path)")
            }
            let source = try await ShareableContentService.resolve(selector)
            let recordingPaths = try RecordingFileManager.makePaths(
                outputDirectory: outputDirectory,
                applicationName: source.snapshot.name
            )
            state = RecorderState(
                phase: .starting,
                sessionID: UUID(),
                processID: getpid(),
                applicationName: source.snapshot.name,
                bundleIdentifier: source.snapshot.bundleIdentifier,
                applicationProcessID: source.snapshot.processID,
                startedAt: Date(),
                temporaryOutputPath: recordingPaths.temporary.path,
                finalOutputPath: recordingPaths.final.path,
                temporarySourcesPath: recordingPaths.temporarySources.path,
                finalSourcesPath: recordingPaths.finalSources.path,
                warning: source.warning
            )
            try states.save(state)

            let capture = try MeetingCaptureSession(
                source: source,
                temporaryOutputURL: recordingPaths.temporary,
                temporarySourcesURL: recordingPaths.temporarySources,
                logger: logger,
                failureHandler: { [weak self] error in
                    Task { await self?.stopForLifecycleEvent("capture failed: \(error.localizedDescription)") }
                }
            )
            self.capture = capture
            state.microphoneName = capture.microphoneName
            state.microphoneID = capture.microphoneID
            try states.save(state)
            try await capture.start()
            state.phase = .recording
            try states.save(state)
            logger.log(.info, "Recording started for \(source.snapshot.name), PID \(source.snapshot.processID).")
            return state
        } catch {
            capture = nil
            lock.unlock()
            state.phase = .failed
            state.processID = nil
            state.lastError = error.localizedDescription
            try? states.save(state)
            throw error
        }
    }

    private func stop() async throws -> RecorderState {
        guard let capture else { throw MeetingRecorderError.notRecording }
        self.capture = nil
        state.phase = .finalizing
        try states.save(state)
        do {
            let result = try await capture.stop()
            state.metrics = result.metrics
            guard let temporary = state.temporaryOutputPath,
                  let preferredFinal = state.finalOutputPath,
                  let temporarySources = state.temporarySourcesPath,
                  let preferredSources = state.finalSourcesPath else {
                throw MeetingRecorderError.io("Recording state does not contain output paths.")
            }
            let finalized = try await RecordingFileManager.finalizePair(
                mixedTemporary: URL(fileURLWithPath: temporary),
                mixedFinal: URL(fileURLWithPath: preferredFinal),
                sourcesTemporary: URL(fileURLWithPath: temporarySources),
                sourcesFinal: URL(fileURLWithPath: preferredSources)
            )
            state.phase = .idle
            state.processID = nil
            state.finalOutputPath = finalized.mixed.path
            state.finalSourcesPath = finalized.sources.path
            state.temporaryOutputPath = nil
            state.temporarySourcesPath = nil
            state.lastError = nil
            try states.save(state)
            lock.unlock()
            logger.log(.info, "Recording finalized at \(finalized.mixed.path), with source tracks at \(finalized.sources.path).")
            return state
        } catch {
            state.phase = .failed
            state.processID = nil
            state.lastError = error.localizedDescription
            try? states.save(state)
            lock.unlock()
            throw error
        }
    }

    private func startMessage(_ state: RecorderState) -> String {
        var message = "Recording \(state.applicationName ?? "meeting")"
        if let warning = state.warning { message += ". \(warning)" }
        return message
    }

    private func statusMessage() -> String {
        switch state.phase {
        case .idle:
            if let mixed = state.finalOutputPath {
                let sources = state.finalSourcesPath.map { "; source tracks: \($0)" } ?? ""
                return "Idle. Last saved: \(mixed)\(sources)"
            }
            return "Idle"
        case .starting: return "Starting \(state.applicationName ?? "recording")"
        case .recording: return "Recording \(state.applicationName ?? "meeting")"
        case .finalizing: return "Finalizing recording"
        case .failed: return "Failed: \(state.lastError ?? "unknown error")"
        }
    }
}
