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
