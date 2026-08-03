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
    private var lastProgressNotificationStage: RecorderTranscriptionStage?
    private var lastProgressNotificationBucket = -1
    private var debugLoggingEnabled = false
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
        if state.phase != .idle, let debugLogPath = state.debugLogPath {
            logger.setSupplementalFile(URL(fileURLWithPath: debugLogPath))
            debugLoggingEnabled = true
            debugLog("Agent resumed session state in phase \(state.phase.rawValue).")
        }
        if state.phase == .transcribing {
            guard let inputPath = state.transcriptionInputPath ?? state.finalSourcesPath,
                  FileManager.default.fileExists(atPath: inputPath) else {
                state.phase = .idle
                state.processID = nil
                state.warning = "Transcription could not resume because its audio input is missing."
                try? states.save(state)
                endSessionDebugLogging()
                return
            }
            guard (try? lock.tryLock()) == true else {
                state.phase = .failed
                state.lastError = "Transcription could not resume because another recorder owns the session lock."
                try? states.save(state)
                endSessionDebugLogging()
                return
            }
            state.processID = getpid()
            state.transcriptionProgress = RecorderTranscriptionProgress(
                stage: .preparing,
                fractionCompleted: 0
            )
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
                let debugLogURL = state.debugLogPath.map(URL.init(fileURLWithPath:))
                debugLog("Recovered recording is below the configured minimum and will be discarded.")
                endSessionDebugLogging()
                try? RecordingFileManager.discardTemporarySession(
                    files: [temporary] + [temporarySources, debugLogURL].compactMap { $0 }
                )
                state.phase = .idle
                state.processID = nil
                state.temporaryOutputPath = nil
                state.temporarySourcesPath = nil
                state.finalOutputPath = nil
                state.finalSourcesPath = nil
                state.debugLogPath = nil
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
        endSessionDebugLogging()
    }

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        lastActivity = Date()
        guard request.version == 1 else {
            return IPCResponse(requestID: request.requestID, success: false, message: "Unsupported IPC version \(request.version).")
        }
        let commandLabel = ipcCommandLabel(request.command)
        if commandLabel != "status" { debugLog("IPC command received: \(commandLabel).") }
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
                let debug = state.debugLogPath.map { "\nDebug log: \($0)" } ?? ""
                return IPCResponse(
                    requestID: request.requestID,
                    success: true,
                    message: "Saved \(finalOutputPath)\(sources)\(transcription)\(debug)",
                    state: state
                )
            case .transcribeFile(let path):
                let state = try await startFileTranscription(path: path)
                let selectedPath = state.transcriptionInputPath ?? path
                let inputExplanation = URL(fileURLWithPath: selectedPath).standardizedFileURL.path
                    == URL(fileURLWithPath: path).standardizedFileURL.path
                    ? ""
                    : " Using the sibling two-track source file: \(selectedPath)."
                let debugExplanation = state.debugLogPath.map { " Debug log: \($0)." } ?? ""
                return IPCResponse(
                    requestID: request.requestID,
                    success: true,
                    message: "Retranscription started for \(path).\(inputExplanation)\(debugExplanation) Use `meeting-recorder status` to follow it.",
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
        if let notificationAuthorizationTask {
            await notificationAuthorizationTask.value
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
            let debugLogURL = beginSessionDebugLogging(
                enabled: configuration.debugEnabled,
                directory: recordingPaths.final.deletingLastPathComponent()
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
                debugLogPath: debugLogURL?.path,
                warning: source.warning
            )
            debugLog(
                "Recording session configured: bundleID=\(source.snapshot.bundleIdentifier), pid=\(source.snapshot.processID), outputDirectory=\(outputDirectory.path), minimumDuration=\(configuration.minimumDuration), language=\(configuration.language.rawValue), diarization=\(configuration.diarizationEnabled), speakerCount=\(configuration.speakerCount.map(String.init) ?? "auto")."
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
            debugLog("Capture became operational: microphoneID=\(capture.microphoneID), two audio outputs observed.")
            return state
        } catch {
            debugLog("Recording start failed: \(error.localizedDescription)")
            endSessionDebugLogging()
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
            debugLog(
                "Capture stopped: applicationRMSDB=\(formatMetric(result.metrics.applicationRMSLevelDB)), applicationPeakDB=\(formatMetric(result.metrics.applicationPeakLevelDB)), microphoneRMSDB=\(formatMetric(result.metrics.microphoneRMSLevelDB)), microphonePeakDB=\(formatMetric(result.metrics.microphonePeakLevelDB)), gaps=\(result.metrics.gapFrames), late=\(result.metrics.lateFrames), overlaps=\(result.metrics.overlapFrames), clipping=\(result.metrics.clippedSamples), backpressure=\(result.metrics.writerBackpressureEvents)."
            )
            if result.metrics.applicationIsEffectivelySilent {
                let level = result.metrics.applicationPeakLevelDB.map { String(format: "%.1f", $0) } ?? "unknown"
                appendWarning(
                    "Application audio was effectively silent (peak \(level) dBFS). If other participants spoke, record the main Google Chrome application instead of its installed Google Meet app."
                )
                logger.log(.warning, "Application audio was effectively silent; no notification was sent while recording.")
            }
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
                let debugLogURL = state.debugLogPath.map(URL.init(fileURLWithPath:))
                debugLog("Recording will be discarded: durationSeconds=\(String(format: "%.3f", mediaDuration)), configuredMinimum=\(minimumDuration).")
                endSessionDebugLogging()
                try RecordingFileManager.discardTemporarySession(
                    files: [temporaryURL, temporarySourcesURL] + [debugLogURL].compactMap { $0 }
                )
                state.phase = .idle
                state.processID = nil
                state.finalOutputPath = nil
                state.finalSourcesPath = nil
                state.temporaryOutputPath = nil
                state.temporarySourcesPath = nil
                state.debugLogPath = nil
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
            state.rawTranscriptPath = nil
            state.transcriptionProgress = RecorderTranscriptionProgress(
                stage: .preparing,
                fractionCompleted: 0
            )
            state.temporaryOutputPath = nil
            state.temporarySourcesPath = nil
            state.lastError = nil
            try states.save(state)
            logger.log(.info, "Recording finalized at \(finalized.mixed.path), with source tracks at \(finalized.sources.path).")
            debugLog("Recording files finalized: durationSeconds=\(String(format: "%.3f", mediaDuration)), mixed=\(finalized.mixed.lastPathComponent), sources=\(finalized.sources.lastPathComponent).")
            beginNotificationAuthorizationRequest()
            launchTranscription(audioURL: finalized.sources)
            return state
        } catch {
            debugLog("Recording finalization failed: \(error.localizedDescription)")
            endSessionDebugLogging()
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
            var lines: [String]
            if let mixed = state.finalOutputPath {
                let sources = state.finalSourcesPath.map { "; source tracks: \($0)" } ?? ""
                let transcript = state.transcriptPath.map { "; transcript: \($0)" } ?? ""
                let rawTranscript = state.rawTranscriptPath.map { "; raw debug transcript: \($0)" } ?? ""
                let debugLog = state.debugLogPath.map { "; debug log: \($0)" } ?? ""
                let warning = state.warning.map { "; warning: \($0)" } ?? ""
                lines = ["Idle. Last saved: \(mixed)\(sources)\(transcript)\(rawTranscript)\(debugLog)\(warning)"]
            } else if let warning = state.warning {
                lines = ["Idle. \(warning)"]
            } else {
                lines = ["Idle"]
            }
            if let progress = state.transcriptionProgress {
                lines.append(contentsOf: transcriptionProgressLines(progress))
            }
            return lines.joined(separator: "\n")
        case .starting: return "Starting \(state.applicationName ?? "recording")"
        case .recording: return "Recording \(state.applicationName ?? "meeting")"
        case .finalizing: return "Finalizing recording"
        case .transcribing:
            var lines = ["Transcribing: \(state.transcriptionInputPath ?? state.finalSourcesPath ?? "audio")"]
            if let debugLogPath = state.debugLogPath { lines.append("Debug log: \(debugLogPath)") }
            if let progress = state.transcriptionProgress {
                lines.append(contentsOf: transcriptionProgressLines(progress))
            }
            return lines.joined(separator: "\n")
        case .failed: return "Failed: \(state.lastError ?? "unknown error")"
        }
    }

    private func transcriptionProgressLines(_ progress: RecorderTranscriptionProgress) -> [String] {
        var lines = [
            "Progress: \(Int((progress.fractionCompleted * 100).rounded()))%",
            "Stage: \(transcriptionStageLabel(progress.stage))",
        ]
        if !progress.detectedLanguages.isEmpty {
            lines.append("Detected languages: \(progress.detectedLanguages.map(languageDisplayName).joined(separator: ", "))")
        }
        if !progress.participants.isEmpty {
            lines.append("Participants: \(progress.participants.joined(separator: ", "))")
        }
        if let error = progress.error { lines.append("Transcription error: \(error)") }
        return lines
    }

    private func transcriptionStageLabel(_ stage: RecorderTranscriptionStage) -> String {
        switch stage {
        case .preparing: return "Preparing audio"
        case .loadingModel: return "Loading transcription model"
        case .transcribingMeeting: return "Transcribing meeting audio"
        case .transcribingMicrophone: return "Transcribing microphone audio"
        case .identifyingParticipants: return "Identifying participants"
        case .writingTranscript: return "Writing transcript"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private func languageDisplayName(_ code: String) -> String {
        switch code.lowercased() {
        case "en", "english": return "English (en)"
        case "fr", "french": return "French (fr)"
        default: return code
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
        let requestedURL = URL(fileURLWithPath: path).standardizedFileURL
        let audioURL = RecordingFileManager.preferredTranscriptionInput(for: requestedURL)
        guard FileManager.default.fileExists(atPath: audioURL.path),
              FileManager.default.isReadableFile(atPath: audioURL.path) else {
            throw MeetingRecorderError.io("Audio file is missing or unreadable: \(audioURL.path)")
        }
        guard try lock.tryLock() else { throw MeetingRecorderError.alreadyRecording }
        do {
            let configuration = try configurations.load()
            let debugLogURL = beginSessionDebugLogging(
                enabled: configuration.debugEnabled,
                directory: audioURL.deletingLastPathComponent()
            )
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
            state.debugLogPath = debugLogURL?.path
            let existingTranscript = MeetingTranscriber.transcriptURL(for: audioURL)
            let existingRawTranscript = MeetingTranscriber.rawTranscriptURL(for: audioURL)
            state.transcriptPath = FileManager.default.fileExists(atPath: existingTranscript.path)
                ? existingTranscript.path
                : nil
            state.rawTranscriptPath = configuration.debugEnabled
                && FileManager.default.fileExists(atPath: existingRawTranscript.path)
                ? existingRawTranscript.path
                : nil
            state.transcriptionProgress = RecorderTranscriptionProgress(
                stage: .preparing,
                fractionCompleted: 0
            )
            state.warning = nil
            state.lastError = nil
            try states.save(state)
            debugLog(
                "Manual transcription started: input=\(audioURL.lastPathComponent), audioTracks=\(tracks.count), durationSeconds=\(String(format: "%.3f", duration.seconds)), model=\(configuration.transcriptionModel), language=\(configuration.language.rawValue), diarization=\(configuration.diarizationEnabled)."
            )
            launchTranscription(audioURL: audioURL)
            return state
        } catch {
            debugLog("Manual transcription setup failed: \(error.localizedDescription)")
            endSessionDebugLogging()
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
        let sessionID = state.sessionID
        let debugEnabled = debugLoggingEnabled
        let diagnosticLogger = logger
        lastProgressNotificationStage = nil
        lastProgressNotificationBucket = -1
        let configuration: RecorderConfiguration
        do {
            configuration = try configurations.load()
        } catch {
            transcriptionTask = Task { [weak self] in
                await self?.transcriptionDidFail("Configuration could not be loaded: \(error.localizedDescription)")
            }
            return
        }
        let progressHandler: MeetingTranscriptionProgressHandler = { [weak self] progress in
            Task {
                await self?.transcriptionProgressDidUpdate(progress, sessionID: sessionID)
            }
        }
        let diagnosticHandler: MeetingTranscriptionDiagnosticHandler?
        if debugEnabled {
            diagnosticHandler = { message in
                diagnosticLogger.log(.info, "DEBUG \(message)")
            }
        } else {
            diagnosticHandler = nil
        }
        transcriptionTask = Task { [weak self] in
            do {
                guard let self else { return }
                let result = try await MeetingTranscriber.transcribe(
                    audioURL: audioURL,
                    modelDirectory: modelDirectory,
                    model: configuration.transcriptionModel,
                    language: configuration.language,
                    diarizationEnabled: configuration.diarizationEnabled,
                    speakerCount: configuration.speakerCount,
                    debugEnabled: debugEnabled,
                    progressHandler: progressHandler,
                    diagnosticHandler: diagnosticHandler
                )
                await self.transcriptionDidFinish(result)
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
        state.rawTranscriptPath = result.rawTranscriptURL?.path
        state.transcriptionProgress = RecorderTranscriptionProgress(
            stage: .completed,
            fractionCompleted: 1,
            detectedLanguages: result.detectedLanguages,
            participants: result.participants
        )
        state.warning = mergedWarning(state.warning, result.warning)
        state.lastError = nil
        lastActivity = Date()
        try? states.save(state)
        logger.log(.info, "Local transcription completed at \(result.transcriptURL.path).")
        debugLog(
            "Transcription completed: cleanTranscript=\(result.transcriptURL.lastPathComponent), rawTranscript=\(result.rawTranscriptURL?.lastPathComponent ?? "disabled"), languages=\(result.detectedLanguages.joined(separator: ",")), participants=\(result.participants.count), warning=\(result.warning != nil)."
        )
        await RecorderNotifications.transcriptionCompleted(
            transcriptURL: result.transcriptURL,
            warning: state.warning,
            sessionID: state.sessionID
        )
        endSessionDebugLogging()
        lock.unlock()
    }

    private func transcriptionDidFail(_ message: String) async {
        transcriptionTask = nil
        state.phase = .idle
        state.processID = nil
        state.transcriptionProgress = RecorderTranscriptionProgress(
            stage: .failed,
            fractionCompleted: state.transcriptionProgress?.fractionCompleted ?? 0,
            detectedLanguages: state.transcriptionProgress?.detectedLanguages ?? [],
            participants: state.transcriptionProgress?.participants ?? [],
            error: message
        )
        state.warning = mergedWarning(
            state.warning,
            "Audio was preserved, but local transcription failed: \(message)"
        )
        state.lastError = nil
        lastActivity = Date()
        try? states.save(state)
        logger.log(.error, "Local transcription failed: \(message)")
        debugLog("Transcription failed: \(message)")
        await RecorderNotifications.transcriptionFailed(message, sessionID: state.sessionID)
        endSessionDebugLogging()
        lock.unlock()
    }

    private func transcriptionProgressDidUpdate(
        _ progress: RecorderTranscriptionProgress,
        sessionID: UUID?
    ) async {
        guard state.phase == .transcribing, state.sessionID == sessionID, capture == nil else { return }
        if let current = state.transcriptionProgress {
            if progress.fractionCompleted < current.fractionCompleted { return }
            if progress.fractionCompleted == current.fractionCompleted,
               transcriptionStageRank(progress.stage) < transcriptionStageRank(current.stage) {
                return
            }
        }
        state.transcriptionProgress = progress
        lastActivity = Date()
        try? states.save(state)
        guard let sessionID else { return }
        let progressBucket = Int(progress.fractionCompleted * 10)
        let stageChanged = progress.stage != lastProgressNotificationStage
        guard stageChanged || progressBucket > lastProgressNotificationBucket else { return }
        lastProgressNotificationStage = progress.stage
        lastProgressNotificationBucket = max(lastProgressNotificationBucket, progressBucket)
        await RecorderNotifications.transcriptionProgress(
            progress,
            sessionID: sessionID,
            sourceName: state.applicationName
        )
    }

    private func transcriptionStageRank(_ stage: RecorderTranscriptionStage) -> Int {
        switch stage {
        case .preparing: return 0
        case .loadingModel: return 1
        case .transcribingMeeting: return 2
        case .transcribingMicrophone: return 3
        case .identifyingParticipants: return 4
        case .writingTranscript: return 5
        case .completed, .failed: return 6
        }
    }

    private func discardedMessage(duration: TimeInterval, minimumDuration: TimeInterval) -> String {
        "Discarded recording because its duration was \(String(format: "%.1f", duration)) seconds, below the configured \(String(format: "%g", minimumDuration))-second minimum."
    }

    private func beginSessionDebugLogging(enabled: Bool, directory: URL) -> URL? {
        logger.setSupplementalFile(nil)
        debugLoggingEnabled = false
        guard enabled else { return nil }
        let url = directory.appendingPathComponent("meeting-recorder.debug.log")
        logger.setSupplementalFile(url)
        debugLoggingEnabled = true
        debugLog("Session debug logging enabled. Transcript text and meeting/window titles are intentionally omitted from logs.")
        return url
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        logger.log(.info, "DEBUG \(message)")
    }

    private func endSessionDebugLogging() {
        guard debugLoggingEnabled else { return }
        debugLog("Session debug logging ended.")
        logger.setSupplementalFile(nil)
        debugLoggingEnabled = false
    }

    private func formatMetric(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "unavailable"
    }

    private func ipcCommandLabel(_ command: RecorderCommand) -> String {
        switch command {
        case .setup: return "setup"
        case .list: return "list"
        case .start: return "start"
        case .stop: return "stop"
        case .transcribeFile: return "transcribe"
        case .status: return "status"
        case .configList: return "config-list"
        case .configGet: return "config-get"
        case .configSet: return "config-set"
        case .configGetOutputDirectory: return "config-get-output-directory"
        case .configSetOutputDirectory: return "config-set-output-directory"
        }
    }

    private func appendWarning(_ warning: String) {
        state.warning = mergedWarning(state.warning, warning)
    }

    private func mergedWarning(_ first: String?, _ second: String?) -> String? {
        let values = [first, second].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return Array(NSOrderedSet(array: values))
            .compactMap { $0 as? String }
            .joined(separator: " ")
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
