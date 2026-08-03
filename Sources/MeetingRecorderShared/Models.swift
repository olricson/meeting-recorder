import Foundation

public enum RecorderPhase: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case finalizing
    case transcribing
    case failed
}

public struct RecorderMetrics: Codable, Equatable, Sendable {
    public var lateFrames: Int64
    public var gapFrames: Int64
    public var overlapFrames: Int64
    public var clippedSamples: Int64
    public var writerBackpressureEvents: Int64

    public init(
        lateFrames: Int64 = 0,
        gapFrames: Int64 = 0,
        overlapFrames: Int64 = 0,
        clippedSamples: Int64 = 0,
        writerBackpressureEvents: Int64 = 0
    ) {
        self.lateFrames = lateFrames
        self.gapFrames = gapFrames
        self.overlapFrames = overlapFrames
        self.clippedSamples = clippedSamples
        self.writerBackpressureEvents = writerBackpressureEvents
    }
}

public struct RecorderState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var phase: RecorderPhase
    public var sessionID: UUID?
    public var processID: Int32?
    public var applicationName: String?
    public var bundleIdentifier: String?
    public var applicationProcessID: Int32?
    public var microphoneName: String?
    public var microphoneID: String?
    public var startedAt: Date?
    public var temporaryOutputPath: String?
    public var finalOutputPath: String?
    public var temporarySourcesPath: String?
    public var finalSourcesPath: String?
    public var transcriptionInputPath: String?
    public var transcriptPath: String?
    public var warning: String?
    public var lastError: String?
    public var metrics: RecorderMetrics

    public init(
        phase: RecorderPhase = .idle,
        sessionID: UUID? = nil,
        processID: Int32? = nil,
        applicationName: String? = nil,
        bundleIdentifier: String? = nil,
        applicationProcessID: Int32? = nil,
        microphoneName: String? = nil,
        microphoneID: String? = nil,
        startedAt: Date? = nil,
        temporaryOutputPath: String? = nil,
        finalOutputPath: String? = nil,
        temporarySourcesPath: String? = nil,
        finalSourcesPath: String? = nil,
        transcriptionInputPath: String? = nil,
        transcriptPath: String? = nil,
        warning: String? = nil,
        lastError: String? = nil,
        metrics: RecorderMetrics = .init()
    ) {
        self.schemaVersion = Self.schemaVersion
        self.phase = phase
        self.sessionID = sessionID
        self.processID = processID
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.applicationProcessID = applicationProcessID
        self.microphoneName = microphoneName
        self.microphoneID = microphoneID
        self.startedAt = startedAt
        self.temporaryOutputPath = temporaryOutputPath
        self.finalOutputPath = finalOutputPath
        self.temporarySourcesPath = temporarySourcesPath
        self.finalSourcesPath = finalSourcesPath
        self.transcriptionInputPath = transcriptionInputPath
        self.transcriptPath = transcriptPath
        self.warning = warning
        self.lastError = lastError
        self.metrics = metrics
    }
}

public enum TranscriptionLanguage: String, Codable, CaseIterable, Sendable {
    case automatic = "auto"
    case english = "en"
    case french = "fr"
}

public enum RecorderConfigurationKey: String, Codable, CaseIterable, Sendable {
    case outputDirectory = "output-directory"
    case transcriptionModel = "transcription-model"
    case minimumDuration = "minimum-duration"
    case language
    case diarization
    case speakerCount = "speaker-count"
}

public struct RecorderConfiguration: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public static let defaultTranscriptionModel = "large-v3-v20240930_626MB"
    public static let defaultMinimumDuration: TimeInterval = 30

    public var schemaVersion: Int
    public var outputDirectory: String
    public var transcriptionModel: String
    public var minimumDuration: TimeInterval
    public var language: TranscriptionLanguage
    public var diarizationEnabled: Bool
    public var speakerCount: Int?

    public init(
        outputDirectory: String,
        transcriptionModel: String = Self.defaultTranscriptionModel,
        minimumDuration: TimeInterval = Self.defaultMinimumDuration,
        language: TranscriptionLanguage = .automatic,
        diarizationEnabled: Bool = true,
        speakerCount: Int? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.outputDirectory = outputDirectory
        self.transcriptionModel = transcriptionModel
        self.minimumDuration = minimumDuration
        self.language = language
        self.diarizationEnabled = diarizationEnabled
        self.speakerCount = speakerCount
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, outputDirectory, transcriptionModel, minimumDuration
        case language, diarizationEnabled, speakerCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = Self.schemaVersion
        self.outputDirectory = try container.decode(String.self, forKey: .outputDirectory)
        self.transcriptionModel = try container.decodeIfPresent(String.self, forKey: .transcriptionModel)
            ?? Self.defaultTranscriptionModel
        self.minimumDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .minimumDuration)
            ?? Self.defaultMinimumDuration
        self.language = try container.decodeIfPresent(TranscriptionLanguage.self, forKey: .language) ?? .automatic
        self.diarizationEnabled = try container.decodeIfPresent(Bool.self, forKey: .diarizationEnabled) ?? true
        self.speakerCount = try container.decodeIfPresent(Int.self, forKey: .speakerCount)
    }

    public func value(for key: RecorderConfigurationKey) -> String {
        switch key {
        case .outputDirectory: return outputDirectory
        case .transcriptionModel: return transcriptionModel
        case .minimumDuration: return Self.formatDuration(minimumDuration)
        case .language: return language.rawValue
        case .diarization: return String(diarizationEnabled)
        case .speakerCount: return speakerCount.map(String.init) ?? "auto"
        }
    }

    private static func formatDuration(_ value: TimeInterval) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

public struct ApplicationSnapshot: Codable, Hashable, Sendable {
    public var name: String
    public var bundleIdentifier: String
    public var processID: Int32

    public init(name: String, bundleIdentifier: String, processID: Int32) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
    }
}

public struct WindowSnapshot: Codable, Hashable, Sendable {
    public var windowID: UInt32
    public var title: String
    public var ownerName: String?
    public var ownerBundleIdentifier: String?
    public var ownerProcessID: Int32?
    public var isOnScreen: Bool

    public init(
        windowID: UInt32,
        title: String,
        ownerName: String?,
        ownerBundleIdentifier: String?,
        ownerProcessID: Int32?,
        isOnScreen: Bool
    ) {
        self.windowID = windowID
        self.title = title
        self.ownerName = ownerName
        self.ownerBundleIdentifier = ownerBundleIdentifier
        self.ownerProcessID = ownerProcessID
        self.isOnScreen = isOnScreen
    }
}

public struct ContentSnapshot: Codable, Equatable, Sendable {
    public var applications: [ApplicationSnapshot]
    public var windows: [WindowSnapshot]

    public init(applications: [ApplicationSnapshot], windows: [WindowSnapshot]) {
        self.applications = applications
        self.windows = windows
    }
}

public enum SourceSelector: Codable, Equatable, Sendable {
    case automatic
    case applicationName(String)
    case bundleIdentifier(String)
    case processID(Int32)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case automatic, applicationName, bundleIdentifier, processID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .automatic: self = .automatic
        case .applicationName: self = .applicationName(try container.decode(String.self, forKey: .value))
        case .bundleIdentifier: self = .bundleIdentifier(try container.decode(String.self, forKey: .value))
        case .processID: self = .processID(try container.decode(Int32.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Kind.automatic, forKey: .kind)
        case .applicationName(let value):
            try container.encode(Kind.applicationName, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .bundleIdentifier(let value):
            try container.encode(Kind.bundleIdentifier, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .processID(let value):
            try container.encode(Kind.processID, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public enum RecorderCommand: Codable, Equatable, Sendable {
    case setup
    case list
    case start(SourceSelector)
    case stop
    case status
    case transcribeFile(String)
    case configList
    case configGet(RecorderConfigurationKey)
    case configSet(RecorderConfigurationKey, String)
    case configGetOutputDirectory
    case configSetOutputDirectory(String)

    private enum CodingKeys: String, CodingKey { case kind, selector, key, value }
    private enum Kind: String, Codable {
        case setup, list, start, stop, status, transcribeFile
        case configList, configGet, configSet, configGetOutputDirectory, configSetOutputDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .setup: self = .setup
        case .list: self = .list
        case .start: self = .start(try container.decode(SourceSelector.self, forKey: .selector))
        case .stop: self = .stop
        case .status: self = .status
        case .transcribeFile: self = .transcribeFile(try container.decode(String.self, forKey: .value))
        case .configList: self = .configList
        case .configGet: self = .configGet(try container.decode(RecorderConfigurationKey.self, forKey: .key))
        case .configSet:
            self = .configSet(
                try container.decode(RecorderConfigurationKey.self, forKey: .key),
                try container.decode(String.self, forKey: .value)
            )
        case .configGetOutputDirectory: self = .configGetOutputDirectory
        case .configSetOutputDirectory:
            self = .configSetOutputDirectory(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setup: try container.encode(Kind.setup, forKey: .kind)
        case .list: try container.encode(Kind.list, forKey: .kind)
        case .start(let selector):
            try container.encode(Kind.start, forKey: .kind)
            try container.encode(selector, forKey: .selector)
        case .stop: try container.encode(Kind.stop, forKey: .kind)
        case .status: try container.encode(Kind.status, forKey: .kind)
        case .transcribeFile(let value):
            try container.encode(Kind.transcribeFile, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .configList: try container.encode(Kind.configList, forKey: .kind)
        case .configGet(let key):
            try container.encode(Kind.configGet, forKey: .kind)
            try container.encode(key, forKey: .key)
        case .configSet(let key, let value):
            try container.encode(Kind.configSet, forKey: .kind)
            try container.encode(key, forKey: .key)
            try container.encode(value, forKey: .value)
        case .configGetOutputDirectory: try container.encode(Kind.configGetOutputDirectory, forKey: .kind)
        case .configSetOutputDirectory(let value):
            try container.encode(Kind.configSetOutputDirectory, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct IPCRequest: Codable, Sendable {
    public var version: Int
    public var requestID: UUID
    public var command: RecorderCommand

    public init(command: RecorderCommand) {
        self.version = 1
        self.requestID = UUID()
        self.command = command
    }
}

public struct IPCResponse: Codable, Sendable {
    public var version: Int
    public var requestID: UUID
    public var success: Bool
    public var message: String
    public var state: RecorderState?
    public var content: ContentSnapshot?
    public var outputDirectory: String?
    public var configuration: RecorderConfiguration?

    public init(
        requestID: UUID,
        success: Bool,
        message: String,
        state: RecorderState? = nil,
        content: ContentSnapshot? = nil,
        outputDirectory: String? = nil,
        configuration: RecorderConfiguration? = nil
    ) {
        self.version = 1
        self.requestID = requestID
        self.success = success
        self.message = message
        self.state = state
        self.content = content
        self.outputDirectory = outputDirectory
        self.configuration = configuration
    }
}

public enum MeetingRecorderError: LocalizedError, Equatable {
    case invalidArgument(String)
    case unavailable(String)
    case permissionDenied(String)
    case alreadyRecording
    case notRecording
    case ambiguousSource(String)
    case sourceNotFound(String)
    case io(String)
    case capture(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let value), .unavailable(let value), .permissionDenied(let value),
             .ambiguousSource(let value), .sourceNotFound(let value), .io(let value), .capture(let value):
            return value
        case .alreadyRecording: return "A recording or transcription is already active."
        case .notRecording: return "No recording is active."
        }
    }
}
