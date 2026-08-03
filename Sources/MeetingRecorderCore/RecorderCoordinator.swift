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
    private var transcriptionTask: Task<Void, Never>?
    private var notificationAuthorizationTask: Task<Void, Never>?
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
        if state.phase == .transcribing {
            guard let inputPath = state.transcriptionInputPath ?? state.finalSourcesPath,
                  FileManager.default.fileExists(atPath: inputPath) else {
                state.phase = .idle
                state.processID = nil
                state.warning = "Transcription could not resume because its audio input is missing."
                try? states.save(state)
                return
            }
            guard (try? lock.tryLock()) == true else {
                state.phase = .failed
                state.lastError = "Transcription could not resume because another recorder owns the session lock."
                try? states.save(state)
                return
            }
            state.processID = getpid()
            try? states.save(state)
            launchTranscription(audioURL: URL(fileURLWithPath: inputPath))
            return
        }
        guard state.phase == .starting || state.phase == .recording || state.phase == .finalizing else { return }
        let minimumDuration = (try? configurations.load().minimumDuration)
            ?? RecorderConfiguration.defaultMinimumDuration
        if let path = state.temporaryOutputPath {
            let temporary = URL(fileURLWithPath: path)
            let temporarySources = state.temporarySourcesPath.map(URL.init(fileURLWithPath:))
            if let mediaDuration = try? await RecordingFileManager.duration(of: temporary),
               !RecordingFileManager.shouldKeepRecording(
                    duration: mediaDuration,
                    minimumDuration: minimumDuration
               ) {
                try? RecordingFileManager.discardTemporarySession(
                    files: [temporary] + [temporarySources].compactMap { $0 }
                )
                state.phase = .idle
                state.processID = nil
                state.temporaryOutputPath = nil
                state.temporarySourcesPath = nil
                state.finalOutputPath = nil
                state.finalSourcesPath = nil
                state.lastError = nil
                state.warning = discardedMessage(duration: mediaDuration, minimumDuration: minimumDuration)
                try? states.save(state)
                return
            }
            let recovered = await RecordingFileManager.recoverAbandonedRecording(at: temporary)
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
                guard let finalOutputPath = state.finalOutputPath else {
                    return IPCResponse(
                        requestID: request.requestID,
                        success: true,
                        message: state.warning ?? "Recording discarded.",
                        state: state
                    )
                }
                let sources = state.finalSourcesPath.map { "\nSource tracks: \($0)" } ?? ""
                let transcription = state.phase == .transcribing
                    ? "\nLocal transcription and remote-speaker identification are running in the background."
                    : state.transcriptPath.map { "\nTranscript: \($0)" } ?? ""
                return IPCResponse(
                    requestID: request.requestID,
                    success: true,
                    message: "Saved \(finalOutputPath)\(sources)\(transcription)",
                    state: state
                )
            case .transcribeFile(let path):
                let state = try await startFileTranscription(path: path)
                return IPCResponse(
                    requestID: request.requestID,
                    success: true,
                    message: "Retranscription started for \(path). Use `meeting-recorder status` to follow it.",
                    state: state
                )
            case .status:
                return IPCResponse(requestID: request.requestID, success: true, message: statusMessage(), state: state)
            case .configList:
                let configuration = try configurations.load()
                return IPCResponse(
                    requestID: request.requestID,
                    success: true,
                    message: configurationSummary(configuration),
                    configuration: configuration
                )
            case .configGet(let key):
                let configuration = try configurations.load()
                return IPCResponse(
                    requestID: request.requestID,
                    success: true,
                    message: configuration.value(for: key),
                    configuration: configuration
                )
            case .configSet(let key, let value):
                let configuration = try configurations.set(key, value: value)
                return IPCResponse(
                    requestID: request.requestID,
                    success: true,
                    message: "\(key.rawValue) set to \(configuration.value(for: key))",
                    configuration: configuration
                )
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
        capture == nil
            && transcriptionTask == nil
            && notificationAuthorizationTask == nil
            && Date().timeIntervalSince(lastActivity) >= seconds
    }

    private func setup(requestID: UUID) async throws -> IPCResponse {
        try paths.createBaseDirectories()
        _ = try configurations.load()
        let notificationPermission = await RecorderNotifications.permission()
        if notificationPermission == .notDetermined {
            beginNotificationAuthorizationRequest()
        }
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
        let notificationMessage: String
        switch notificationPermission {
        case .enabled:
            notificationMessage = " Transcription notifications are enabled."
        case .notDetermined:
            notificationMessage = " A notification permission request has been opened; choose Allow to receive transcription results."
        case .denied:
            notificationMessage = " Warning: notifications are disabled; enable MeetingRecorder in System Settings > Notifications to receive transcription results."
        }
        let message = "Setup complete for \(expectedBundleID), signed by \(signer). Permissions are local to this Mac.\(notificationMessage)\(locationWarning)"
        return IPCResponse(requestID: requestID, success: true, message: message, state: state)
    }

    private func start(selector: SourceSelector) async throws -> RecorderState {
        guard capture == nil,
              state.phase != .starting,
              state.phase != .recording,
              state.phase != .finalizing,
              state.phase != .transcribing else {
            throw MeetingRecorderError.alreadyRecording
        }
        guard try lock.tryLock() else { throw MeetingRecorderError.alreadyRecording }
        do {
            beginNotificationAuthorizationRequest()
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
            let temporaryURL = URL(fileURLWithPath: temporary)
            let temporarySourcesURL = URL(fileURLWithPath: temporarySources)
            let mediaDuration = try await RecordingFileManager.duration(of: temporaryURL)
            let minimumDuration = try configurations.load().minimumDuration
            if !RecordingFileManager.shouldKeepRecording(
                duration: mediaDuration,
                minimumDuration: minimumDuration
            ) {
                try RecordingFileManager.discardTemporarySession(files: [temporaryURL, temporarySourcesURL])
                state.phase = .idle
                state.processID = nil
                state.finalOutputPath = nil
                state.finalSourcesPath = nil
                state.temporaryOutputPath = nil
                state.temporarySourcesPath = nil
                state.lastError = nil
                state.warning = discardedMessage(duration: mediaDuration, minimumDuration: minimumDuration)
                try states.save(state)
                lock.unlock()
                logger.log(.info, "Discarded a recording shorter than the configured minimum duration.")
                return state
            }
            let finalized = try await RecordingFileManager.finalizePair(
                mixedTemporary: temporaryURL,
                mixedFinal: URL(fileURLWithPath: preferredFinal),
                sourcesTemporary: temporarySourcesURL,
                sourcesFinal: URL(fileURLWithPath: preferredSources)
            )
            state.phase = .transcribing
            state.processID = getpid()
            state.finalOutputPath = finalized.mixed.path
            state.finalSourcesPath = finalized.sources.path
            state.transcriptionInputPath = finalized.sources.path
            state.transcriptPath = nil
            state.temporaryOutputPath = nil
            state.temporarySourcesPath = nil
            state.lastError = nil
            try states.save(state)
            logger.log(.info, "Recording finalized at \(finalized.mixed.path), with source tracks at \(finalized.sources.path).")
            launchTranscription(audioURL: finalized.sources)
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
                let transcript = state.transcriptPath.map { "; transcript: \($0)" } ?? ""
                let warning = state.warning.map { "; warning: \($0)" } ?? ""
                return "Idle. Last saved: \(mixed)\(sources)\(transcript)\(warning)"
            }
            if let warning = state.warning { return "Idle. \(warning)" }
            return "Idle"
        case .starting: return "Starting \(state.applicationName ?? "recording")"
        case .recording: return "Recording \(state.applicationName ?? "meeting")"
        case .finalizing: return "Finalizing recording"
        case .transcribing:
            return "Transcribing \(state.transcriptionInputPath ?? state.finalSourcesPath ?? "audio") and identifying speakers on-device"
        case .failed: return "Failed: \(state.lastError ?? "unknown error")"
        }
    }

    private func configurationSummary(_ configuration: RecorderConfiguration) -> String {
        RecorderConfigurationKey.allCases
            .map { "\($0.rawValue)=\(configuration.value(for: $0))" }
            .joined(separator: "\n")
    }

    private func startFileTranscription(path: String) async throws -> RecorderState {
        guard capture == nil, transcriptionTask == nil, state.phase != .starting,
              state.phase != .recording, state.phase != .finalizing, state.phase != .transcribing else {
            throw MeetingRecorderError.alreadyRecording
        }
        let audioURL = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: audioURL.path),
              FileManager.default.isReadableFile(atPath: audioURL.path) else {
            throw MeetingRecorderError.io("Audio file is missing or unreadable: \(audioURL.path)")
        }
        guard try lock.tryLock() else { throw MeetingRecorderError.alreadyRecording }
        do {
            let asset = AVURLAsset(url: audioURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard tracks.count == 1 || tracks.count == 2 else {
                throw MeetingRecorderError.io(
                    "Audio file must contain one track, or two tracks for separate meeting and microphone audio."
                )
            }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0 else {
                throw MeetingRecorderError.io("Audio file has no readable duration: \(audioURL.path)")
            }
            beginNotificationAuthorizationRequest()
            state.phase = .transcribing
            state.sessionID = UUID()
            state.processID = getpid()
            state.applicationName = audioURL.deletingPathExtension().lastPathComponent
            state.startedAt = Date()
            state.transcriptionInputPath = audioURL.path
            let existingTranscript = MeetingTranscriber.transcriptURL(for: audioURL)
            state.transcriptPath = FileManager.default.fileExists(atPath: existingTranscript.path)
                ? existingTranscript.path
                : nil
            state.warning = nil
            state.lastError = nil
            try states.save(state)
            launchTranscription(audioURL: audioURL)
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

    private func launchTranscription(audioURL: URL) {
        let modelDirectory = paths.transcriptionModelsDirectory
        let configuration: RecorderConfiguration
        do {
            configuration = try configurations.load()
        } catch {
            transcriptionTask = Task { [weak self] in
                await self?.transcriptionDidFail("Configuration could not be loaded: \(error.localizedDescription)")
            }
            return
        }
        transcriptionTask = Task { [weak self] in
            do {
                let result = try await MeetingTranscriber.transcribe(
                    audioURL: audioURL,
                    modelDirectory: modelDirectory,
                    model: configuration.transcriptionModel,
                    language: configuration.language,
                    diarizationEnabled: configuration.diarizationEnabled,
                    speakerCount: configuration.speakerCount
                )
                await self?.transcriptionDidFinish(result)
            } catch {
                await self?.transcriptionDidFail(error.localizedDescription)
            }
        }
    }

    private func beginNotificationAuthorizationRequest() {
        guard notificationAuthorizationTask == nil else { return }
        notificationAuthorizationTask = Task { [weak self] in
            await RecorderNotifications.requestAuthorizationIfNeeded()
            await self?.notificationAuthorizationDidFinish()
        }
    }

    private func notificationAuthorizationDidFinish() {
        notificationAuthorizationTask = nil
        lastActivity = Date()
        logger.log(.info, "Notification authorization request completed.")
    }

    private func transcriptionDidFinish(_ result: MeetingTranscriptionOutput) async {
        transcriptionTask = nil
        state.phase = .idle
        state.processID = nil
        state.transcriptPath = result.transcriptURL.path
        state.warning = result.warning
        state.lastError = nil
        lastActivity = Date()
        try? states.save(state)
        lock.unlock()
        logger.log(.info, "Local transcription completed at \(result.transcriptURL.path).")
        await RecorderNotifications.transcriptionCompleted(
            transcriptURL: result.transcriptURL,
            warning: result.warning
        )
    }

    private func transcriptionDidFail(_ message: String) async {
        transcriptionTask = nil
        state.phase = .idle
        state.processID = nil
        state.warning = "Audio was preserved, but local transcription failed: \(message)"
        state.lastError = nil
        lastActivity = Date()
        try? states.save(state)
        lock.unlock()
        logger.log(.error, "Local transcription failed: \(message)")
        await RecorderNotifications.transcriptionFailed(message)
    }

    private func discardedMessage(duration: TimeInterval, minimumDuration: TimeInterval) -> String {
        "Discarded recording because its duration was \(String(format: "%.1f", duration)) seconds, below the configured \(String(format: "%g", minimumDuration))-second minimum."
    }
}
