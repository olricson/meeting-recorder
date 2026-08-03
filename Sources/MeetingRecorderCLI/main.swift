import AppKit
import Darwin
import Foundation
import MeetingRecorderShared

@main
struct MeetingRecorderCLI {
    static func main() {
        do {
            let invocation = try parse(Array(CommandLine.arguments.dropFirst()))
            let paths = RecorderPaths()
            let response: IPCResponse
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
            guard response.success else {
                fputs("Error: \(response.message)\n", stderr)
                exit(3)
            }
            printResponse(response, commandName: invocation.commandName, asJSON: invocation.json)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            fputs("Run `meeting-recorder help` for usage.\n", stderr)
            exit(2)
        }
    }

    private struct Invocation {
        let commandName: String
        let command: RecorderCommand
        let json: Bool
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
            guard arguments.count == 1 else {
                throw MeetingRecorderError.invalidArgument("Use `transcribe AUDIO_FILE`.")
            }
            return Invocation(
                commandName: command,
                command: .transcribeFile(try canonicalAudioPath(arguments[0])),
                json: json
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
          meeting-recorder transcribe AUDIO_FILE [--json]
          meeting-recorder status [--json]
          meeting-recorder toggle [--app NAME | --bundle-id ID | --pid PID]
          meeting-recorder config list [--json]
          meeting-recorder config get KEY [--json]
          meeting-recorder config set KEY VALUE [--json]

        Configuration keys:
          output-directory, transcription-model, minimum-duration,
          language, diarization, speaker-count
        """)
    }
}
