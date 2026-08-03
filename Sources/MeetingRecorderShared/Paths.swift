import Foundation

public struct RecorderPaths: Sendable {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public var applicationSupportDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/MeetingRecorder", isDirectory: true)
    }

    public var logsDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Logs/MeetingRecorder", isDirectory: true)
    }

    public var defaultOutputDirectory: URL {
        homeDirectory.appendingPathComponent("Meetings Recordings", isDirectory: true)
    }

    public var configFile: URL { applicationSupportDirectory.appendingPathComponent("config.json") }
    public var stateFile: URL { applicationSupportDirectory.appendingPathComponent("state.json") }
    public var lockFile: URL { applicationSupportDirectory.appendingPathComponent("recorder.lock") }
    public var socketFile: URL { applicationSupportDirectory.appendingPathComponent("control.sock") }
    public var logFile: URL { logsDirectory.appendingPathComponent("meeting-recorder.log") }
    public var transcriptionModelsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    public func createBaseDirectories() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: defaultOutputDirectory, withIntermediateDirectories: true)
    }

    public func expandPath(_ path: String) -> URL {
        let expanded: String
        if path == "~" {
            expanded = homeDirectory.path
        } else if path.hasPrefix("~/") {
            expanded = homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            expanded = (path as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}

public enum AtomicJSONStore {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public final class ConfigurationStore: @unchecked Sendable {
    private let paths: RecorderPaths
    private let queue = DispatchQueue(label: "com.olivier.meetingrecorder.configuration")

    public init(paths: RecorderPaths) { self.paths = paths }

    public func load() throws -> RecorderConfiguration {
        try queue.sync { try loadUnlocked() }
    }

    @discardableResult
    public func setOutputDirectory(_ path: String) throws -> RecorderConfiguration {
        try set(.outputDirectory, value: path)
    }

    @discardableResult
    public func set(_ key: RecorderConfigurationKey, value: String) throws -> RecorderConfiguration {
        try queue.sync {
            var configuration = try loadUnlocked()
            switch key {
            case .outputDirectory:
                let url = paths.expandPath(value)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                guard FileManager.default.isWritableFile(atPath: url.path) else {
                    throw MeetingRecorderError.io("Output directory is not writable: \(url.path)")
                }
                configuration.outputDirectory = url.path
            case .transcriptionModel:
                let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty else {
                    throw MeetingRecorderError.invalidArgument("transcription-model cannot be empty.")
                }
                configuration.transcriptionModel = model
            case .minimumDuration:
                guard let duration = TimeInterval(value), duration.isFinite, duration >= 0 else {
                    throw MeetingRecorderError.invalidArgument("minimum-duration must be a nonnegative number of seconds.")
                }
                configuration.minimumDuration = duration
            case .language:
                guard let language = TranscriptionLanguage(rawValue: value.lowercased()) else {
                    throw MeetingRecorderError.invalidArgument("language must be auto, en, or fr.")
                }
                configuration.language = language
            case .diarization:
                switch value.lowercased() {
                case "true", "yes", "on", "1": configuration.diarizationEnabled = true
                case "false", "no", "off", "0": configuration.diarizationEnabled = false
                default: throw MeetingRecorderError.invalidArgument("diarization must be true or false.")
                }
            case .speakerCount:
                if value.lowercased() == "auto" {
                    configuration.speakerCount = nil
                } else if let count = Int(value), (1...20).contains(count) {
                    configuration.speakerCount = count
                } else {
                    throw MeetingRecorderError.invalidArgument("speaker-count must be auto or an integer from 1 through 20.")
                }
            }
            try AtomicJSONStore.save(configuration, to: paths.configFile)
            return configuration
        }
    }

    private func loadUnlocked() throws -> RecorderConfiguration {
        if FileManager.default.fileExists(atPath: paths.configFile.path) {
            return try AtomicJSONStore.load(RecorderConfiguration.self, from: paths.configFile)
        }
        let configuration = RecorderConfiguration(outputDirectory: paths.defaultOutputDirectory.path)
        try AtomicJSONStore.save(configuration, to: paths.configFile)
        return configuration
    }
}
