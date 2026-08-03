import AppKit
import Darwin
import Foundation
import MeetingRecorderShared

@main
struct MeetingRecorderCLI {
    static func main() {
        let paths = RecorderPaths()
        let logger = FileLogger(fileURL: paths.logFile)
        var commandName = "parse"
        do {
            let invocation = try parse(Array(CommandLine.arguments.dropFirst()))
            commandName = invocation.commandName
            var response: IPCResponse
            if invocation.commandName == "toggle" {
                let status = try send(command: .status, paths: paths)
                if status.state?.phase == .transcribing {
                    response = status
                } else if let phase = status.state?.phase, [.starting, .recording, .finalizing].contains(phase) {
                    response = try send(command: .stop, paths: paths)
                } else {
                    response = try send(command: invocation.command, paths: paths)
                }
            } else {
                response = try send(command: invocation.command, paths: paths)
            }
            if invocation.waitForTranscription, response.success {
                response = try waitForTranscription(startResponse: response, paths: paths)
            }
            logCLIDiagnostic(
                logger: logger,
                paths: paths,
                commandName: commandName,
                response: response,
                message: "completed with success=\(response.success)"
            )
            guard response.success else {
                fputs("Error: \(response.message)\n", stderr)
                exit(3)
            }
            printResponse(response, commandName: invocation.commandName, asJSON: invocation.json)
        } catch {
            logCLIDiagnostic(
                logger: logger,
                paths: paths,
                commandName: commandName,
                response: nil,
                message: "failed: \(error.localizedDescription)"
            )
            fputs("Error: \(error.localizedDescription)\n", stderr)
            fputs("Run `meeting-recorder help` for usage.\n", stderr)
            exit(2)
        }
    }

    private static func logCLIDiagnostic(
        logger: FileLogger,
        paths: RecorderPaths,
        commandName: String,
        response: IPCResponse?,
        message: String
    ) {
        let configurationDebug = (try? ConfigurationStore(paths: paths).load().debugEnabled) == true
        let sessionLogPath = response?.state?.debugLogPath
        guard configurationDebug || sessionLogPath != nil else { return }
        if let sessionLogPath {
            logger.setSupplementalFile(URL(fileURLWithPath: sessionLogPath))
        }
        if commandName != "status" {
            logger.log(.info, "DEBUG CLI command \(commandName) \(message).")
        }
        logger.flush()
        logger.setSupplementalFile(nil)
    }

    private struct Invocation {
        let commandName: String
        let command: RecorderCommand
        let json: Bool
        let waitForTranscription: Bool

        init(
            commandName: String,
            command: RecorderCommand,
            json: Bool,
            waitForTranscription: Bool = false
        ) {
            self.commandName = commandName
            self.command = command
            self.json = json
            self.waitForTranscription = waitForTranscription
        }
    }

    private static func parse(_ rawArguments: [String]) throws -> Invocation {
        guard let command = rawArguments.first else { return Invocation(commandName: "status", command: .status, json: false) }
        var arguments = Array(rawArguments.dropFirst())
        let json = removeFlag("--json", from: &arguments)
        switch command {
        case "help", "--help", "-h":
            printUsage()
            exit(0)
        case "setup":
            try requireEmpty(arguments)
            return Invocation(commandName: command, command: .setup, json: json)
        case "list":
            try requireEmpty(arguments)
            return Invocation(commandName: command, command: .list, json: json)
        case "status":
            try requireEmpty(arguments)
            return Invocation(commandName: command, command: .status, json: json)
        case "stop":
            try requireEmpty(arguments)
            return Invocation(commandName: command, command: .stop, json: json)
        case "transcribe":
            let wait = removeFlag("--wait", from: &arguments)
            let synchronousAlias = removeFlag("--sync", from: &arguments)
            guard arguments.count == 1 else {
                throw MeetingRecorderError.invalidArgument("Use `transcribe AUDIO_FILE [--wait]`.")
            }
            return Invocation(
                commandName: command,
                command: .transcribeFile(try canonicalAudioPath(arguments[0])),
                json: json,
                waitForTranscription: wait || synchronousAlias
            )
        case "toggle":
            let selector = try parseSelector(arguments)
            return Invocation(commandName: command, command: .start(selector), json: json)
        case "start":
            let selector = try parseSelector(arguments)
            return Invocation(commandName: command, command: .start(selector), json: json)
        case "config":
            if arguments == ["list"] {
                return Invocation(commandName: command, command: .configList, json: json)
            }
            if arguments.count == 2, arguments[0] == "get",
               let key = RecorderConfigurationKey(rawValue: arguments[1]) {
                return Invocation(commandName: command, command: .configGet(key), json: json)
            }
            if arguments.count == 3, arguments[0] == "set",
               let key = RecorderConfigurationKey(rawValue: arguments[1]) {
                return Invocation(commandName: command, command: .configSet(key, arguments[2]), json: json)
            }
            throw MeetingRecorderError.invalidArgument(
                "Use `config list`, `config get KEY`, or `config set KEY VALUE`."
            )
        default:
            throw MeetingRecorderError.invalidArgument("Unknown command: \(command)")
        }
    }

    private static func parseSelector(_ arguments: [String]) throws -> SourceSelector {
        if arguments.isEmpty { return .automatic }
        guard arguments.count == 2 else {
            throw MeetingRecorderError.invalidArgument("Use at most one of --app NAME, --bundle-id ID, or --pid PID.")
        }
        switch arguments[0] {
        case "--app": return .applicationName(arguments[1])
        case "--bundle-id": return .bundleIdentifier(arguments[1])
        case "--pid":
            guard let value = Int32(arguments[1]), value > 0 else {
                throw MeetingRecorderError.invalidArgument("PID must be a positive integer.")
            }
            return .processID(value)
        default:
            throw MeetingRecorderError.invalidArgument("Unknown source selector option: \(arguments[0])")
        }
    }

    private static func canonicalAudioPath(_ value: String) throws -> String {
        let expanded = (value as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(expanded)
        let canonical = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: canonical.path) else {
            throw MeetingRecorderError.invalidArgument("Audio file does not exist: \(canonical.path)")
        }
        guard FileManager.default.isReadableFile(atPath: canonical.path) else {
            throw MeetingRecorderError.invalidArgument("Audio file is not readable: \(canonical.path)")
        }
        return canonical.path
    }

    private static func send(command: RecorderCommand, paths: RecorderPaths) throws -> IPCResponse {
        let request = IPCRequest(command: command)
        let client = UnixSocketClient()
        if let response = try? client.send(request, to: paths.socketFile) { return response }
        try launchAgent()
        var lastError: Error?
        for _ in 0..<60 {
            usleep(100_000)
            do { return try client.send(request, to: paths.socketFile) }
            catch { lastError = error }
        }
        throw MeetingRecorderError.unavailable(
            "MeetingRecorder.app did not start: \(lastError?.localizedDescription ?? "control socket unavailable")"
        )
    }

    private static func waitForTranscription(
        startResponse: IPCResponse,
        paths: RecorderPaths
    ) throws -> IPCResponse {
        guard let sessionID = startResponse.state?.sessionID else {
            throw MeetingRecorderError.unavailable(
                "The recorder did not return a transcription session identifier. Reinstall the matching app and CLI."
            )
        }
        var lastProgressKey: String?
        reportTranscriptionProgress(startResponse.state, lastProgressKey: &lastProgressKey)

        while true {
            usleep(500_000)
            let response = try send(command: .status, paths: paths)
            guard response.success, let state = response.state else {
                throw MeetingRecorderError.unavailable(response.message)
            }
            guard state.sessionID == sessionID else {
                throw MeetingRecorderError.unavailable(
                    "The active recorder session changed while waiting for transcription."
                )
            }
            reportTranscriptionProgress(state, lastProgressKey: &lastProgressKey)
            if state.phase == .transcribing { continue }

            if let progress = state.transcriptionProgress, progress.stage == .failed {
                throw MeetingRecorderError.io(progress.error ?? state.warning ?? "Transcription failed.")
            }
            guard state.transcriptionProgress?.stage == .completed,
                  let transcriptPath = state.transcriptPath else {
                throw MeetingRecorderError.unavailable(
                    state.lastError ?? state.warning ?? "Transcription ended without producing a transcript."
                )
            }
            let languages = state.transcriptionProgress?.detectedLanguages ?? []
            let participants = state.transcriptionProgress?.participants ?? []
            var lines = ["Transcription complete.", "Transcript: \(transcriptPath)"]
            if let rawTranscriptPath = state.rawTranscriptPath {
                lines.append("Raw debug transcript: \(rawTranscriptPath)")
            }
            if let debugLogPath = state.debugLogPath {
                lines.append("Debug log: \(debugLogPath)")
            }
            lines.append(
                "Detected languages: \(languages.isEmpty ? "none" : languages.map(languageDisplayName).joined(separator: ", "))"
            )
            lines.append(
                "Participants: \(participants.isEmpty ? "none identified" : participants.joined(separator: ", "))"
            )
            if let warning = state.warning { lines.append("Warning: \(warning)") }
            return IPCResponse(
                requestID: response.requestID,
                success: true,
                message: lines.joined(separator: "\n"),
                state: state
            )
        }
    }

    private static func reportTranscriptionProgress(
        _ state: RecorderState?,
        lastProgressKey: inout String?
    ) {
        guard let progress = state?.transcriptionProgress else { return }
        let percent = Int((progress.fractionCompleted * 100).rounded())
        let languages = progress.detectedLanguages.map(languageDisplayName)
        var details: [String] = []
        if !languages.isEmpty { details.append("language: \(languages.joined(separator: ", "))") }
        if !progress.participants.isEmpty {
            details.append("participants: \(progress.participants.joined(separator: ", "))")
        }
        let key = "\(progress.stage.rawValue)|\(percent)|\(languages.joined(separator: ","))|\(progress.participants.joined(separator: ","))"
        guard key != lastProgressKey else { return }
        lastProgressKey = key
        let suffix = details.isEmpty ? "" : " — \(details.joined(separator: "; "))"
        fputs(String(format: "[%3d%%] %@%@\n", percent, transcriptionStageLabel(progress.stage), suffix), stderr)
        fflush(stderr)
    }

    private static func transcriptionStageLabel(_ stage: RecorderTranscriptionStage) -> String {
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

    private static func languageDisplayName(_ code: String) -> String {
        switch code.lowercased() {
        case "en", "english": return "English (en)"
        case "fr", "french": return "French (fr)"
        default: return code
        }
    }

    private static func launchAgent() throws {
        let appURL = try locateApplication()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            launchError = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        if let launchError { throw launchError }
    }

    private static func locateApplication() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MEETING_RECORDER_APP_PATH"] {
            let url = URL(fileURLWithPath: override).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        var cursor = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.pathExtension == "app" { return cursor }
            cursor.deleteLastPathComponent()
        }
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/MeetingRecorder.app")
        if FileManager.default.fileExists(atPath: installed.path) { return installed }
        throw MeetingRecorderError.unavailable(
            "MeetingRecorder.app was not found. Install it in ~/Applications or set MEETING_RECORDER_APP_PATH."
        )
    }

    private static func printResponse(_ response: IPCResponse, commandName: String, asJSON: Bool) {
        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        if commandName == "list", let content = response.content {
            print("Applications:")
            for (index, application) in content.applications.enumerated() {
                print("[\(index + 1)] \(application.name) — \(application.bundleIdentifier) — PID \(application.processID)")
            }
            print("\nWindows:")
            for (index, window) in content.windows.filter({ !$0.title.isEmpty }).enumerated() {
                let owner = window.ownerName ?? "Unknown"
                let pid = window.ownerProcessID.map(String.init) ?? "?"
                print("[\(index + 1)] \(window.title) — \(owner) — PID \(pid)")
            }
            print("\nNote: selecting a window can only identify its owner; audio capture includes the entire owning application.")
        } else {
            print(response.message)
        }
    }

    private static func removeFlag(_ flag: String, from arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        arguments.remove(at: index)
        return true
    }

    private static func requireEmpty(_ arguments: [String]) throws {
        guard arguments.isEmpty else { throw MeetingRecorderError.invalidArgument("Unexpected arguments: \(arguments.joined(separator: " "))") }
    }

    private static func printUsage() {
        print("""
        Usage:
          meeting-recorder setup
          meeting-recorder list [--json]
          meeting-recorder start [--app NAME | --bundle-id ID | --pid PID]
          meeting-recorder stop
          meeting-recorder transcribe AUDIO_FILE [--wait] [--json]
          meeting-recorder status [--json]
          meeting-recorder toggle [--app NAME | --bundle-id ID | --pid PID]
          meeting-recorder config list [--json]
          meeting-recorder config get KEY [--json]
          meeting-recorder config set KEY VALUE [--json]

        Configuration keys:
          output-directory, transcription-model, minimum-duration,
          language, diarization, speaker-count, debug
        """)
    }
}
