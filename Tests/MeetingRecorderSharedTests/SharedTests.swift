import Darwin
import Foundation
@testable import MeetingRecorderShared
import XCTest

final class SharedTests: XCTestCase {
    func testRecorderCommandRoundTripsThroughJSON() throws {
        let request = IPCRequest(command: .start(.bundleIdentifier("com.google.Chrome")))
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.command, .start(.bundleIdentifier("com.google.Chrome")))

        let transcribeRequest = IPCRequest(command: .transcribeFile("/tmp/meeting.m4a"))
        let transcribeData = try JSONEncoder().encode(transcribeRequest)
        let decodedTranscribe = try JSONDecoder().decode(IPCRequest.self, from: transcribeData)
        XCTAssertEqual(decodedTranscribe.command, .transcribeFile("/tmp/meeting.m4a"))

        let configRequest = IPCRequest(command: .configSet(.language, "fr"))
        let configData = try JSONEncoder().encode(configRequest)
        let decodedConfig = try JSONDecoder().decode(IPCRequest.self, from: configData)
        XCTAssertEqual(decodedConfig.command, .configSet(.language, "fr"))
    }

    func testRecorderStateFromOlderBuildDecodesWithoutTranscriptPath() throws {
        let data = Data(#"{"schemaVersion":1,"phase":"idle","metrics":{"lateFrames":0,"gapFrames":0,"overlapFrames":0,"clippedSamples":0,"writerBackpressureEvents":0}}"#.utf8)
        let state = try JSONDecoder().decode(RecorderState.self, from: data)

        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.transcriptionInputPath)
        XCTAssertNil(state.transcriptPath)
    }

    func testConfigurationUsesLocalMeetingsDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderSharedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let paths = RecorderPaths(homeDirectory: temporary)
        try paths.createBaseDirectories()
        let store = ConfigurationStore(paths: paths)
        let configuration = try store.load()
        XCTAssertEqual(configuration.outputDirectory, temporary.appendingPathComponent("Meetings Recordings").path)
        XCTAssertFalse(configuration.outputDirectory.contains("Documents"))
        XCTAssertEqual(configuration.transcriptionModel, RecorderConfiguration.defaultTranscriptionModel)
        XCTAssertEqual(configuration.minimumDuration, 30)
        XCTAssertEqual(configuration.language, .automatic)
        XCTAssertTrue(configuration.diarizationEnabled)
        XCTAssertNil(configuration.speakerCount)
    }

    func testConfiguredPathExpandsTilde() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderSharedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let paths = RecorderPaths(homeDirectory: temporary)
        try paths.createBaseDirectories()
        let configuration = try ConfigurationStore(paths: paths).setOutputDirectory("~/Private Meetings")
        XCTAssertEqual(configuration.outputDirectory, temporary.appendingPathComponent("Private Meetings").path)
    }

    func testConfigurationStoreValidatesAndPersistsTranscriptionSettings() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderConfigTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = ConfigurationStore(paths: RecorderPaths(homeDirectory: temporary))

        _ = try store.set(.transcriptionModel, value: "small-model")
        _ = try store.set(.minimumDuration, value: "12.5")
        _ = try store.set(.language, value: "fr")
        _ = try store.set(.diarization, value: "false")
        let configuration = try store.set(.speakerCount, value: "3")

        XCTAssertEqual(configuration.transcriptionModel, "small-model")
        XCTAssertEqual(configuration.minimumDuration, 12.5)
        XCTAssertEqual(configuration.language, .french)
        XCTAssertFalse(configuration.diarizationEnabled)
        XCTAssertEqual(configuration.speakerCount, 3)
        XCTAssertThrowsError(try store.set(.speakerCount, value: "21"))
        XCTAssertThrowsError(try store.set(.language, value: "de"))
    }

    func testLegacyConfigurationReceivesNewDefaults() throws {
        let data = Data(#"{"schemaVersion":1,"outputDirectory":"/tmp/meetings"}"#.utf8)
        let configuration = try JSONDecoder().decode(RecorderConfiguration.self, from: data)

        XCTAssertEqual(configuration.schemaVersion, RecorderConfiguration.schemaVersion)
        XCTAssertEqual(configuration.minimumDuration, 30)
        XCTAssertEqual(configuration.language, .automatic)
        XCTAssertTrue(configuration.diarizationEnabled)
    }

    func testUnixSocketRequestResponse() throws {
        let socket = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-socket-\(UUID().uuidString)")
        let server = UnixSocketServer(socketURL: socket) { request in
            IPCResponse(requestID: request.requestID, success: true, message: "pong")
        }
        try server.start()
        defer { server.stop() }
        let response = try UnixSocketClient().send(IPCRequest(command: .status), to: socket, timeout: 2)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.message, "pong")
    }

    func testUnixSocketWaitsForAClientThatConnectsBeforeWriting() throws {
        let socket = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-delayed-socket-\(UUID().uuidString)")
        let server = UnixSocketServer(socketURL: socket) { request in
            IPCResponse(requestID: request.requestID, success: true, message: "delayed pong")
        }
        try server.start()
        defer { server.stop() }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socket.path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        XCTAssertEqual(connected, 0)

        usleep(250_000)
        let request = IPCRequest(command: .status)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var requestData = try encoder.encode(request)
        requestData.append(0x0A)
        let written = requestData.withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(written, requestData.count)

        var responseData = Data()
        var byte: UInt8 = 0
        while Darwin.read(descriptor, &byte, 1) == 1, byte != 0x0A {
            responseData.append(byte)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(IPCResponse.self, from: responseData)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.message, "delayed pong")
    }
}
