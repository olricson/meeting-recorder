import Foundation

public enum RecorderPhase: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case finalizing
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
        self.warning = warning
        self.lastError = lastError
        self.metrics = metrics
    }
}

public struct RecorderConfiguration: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var outputDirectory: String

    public init(outputDirectory: String) {
        self.schemaVersion = Self.schemaVersion
        self.outputDirectory = outputDirectory
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
    case configGetOutputDirectory
    case configSetOutputDirectory(String)

    private enum CodingKeys: String, CodingKey { case kind, selector, value }
    private enum Kind: String, Codable {
        case setup, list, start, stop, status, configGetOutputDirectory, configSetOutputDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .setup: self = .setup
        case .list: self = .list
        case .start: self = .start(try container.decode(SourceSelector.self, forKey: .selector))
        case .stop: self = .stop
        case .status: self = .status
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

    public init(
        requestID: UUID,
        success: Bool,
        message: String,
        state: RecorderState? = nil,
        content: ContentSnapshot? = nil,
        outputDirectory: String? = nil
    ) {
        self.version = 1
        self.requestID = requestID
        self.success = success
        self.message = message
        self.state = state
        self.content = content
        self.outputDirectory = outputDirectory
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
        case .alreadyRecording: return "A recording is already active."
        case .notRecording: return "No recording is active."
        }
    }
}
