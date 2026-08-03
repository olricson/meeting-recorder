import Darwin
import Foundation

public enum UnixSocketError: LocalizedError {
    case system(String, Int32)
    case pathTooLong(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .system(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .pathTooLong(let path): return "Unix socket path is too long: \(path)"
        case .invalidResponse: return "The recorder returned an invalid response."
        }
    }
}

private func socketAddress(for path: String) throws -> (sockaddr_un, socklen_t) {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else { throw UnixSocketError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        bytes.withUnsafeBytes { source in
            destination.copyBytes(from: source)
        }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    return (address, length)
}

public final class UnixSocketClient {
    public init() {}

    public func send(_ request: IPCRequest, to socketURL: URL, timeout: TimeInterval = 30) throws -> IPCResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketError.system("socket", errno) }
        defer { Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var timeoutValue = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))

        var (address, length) = try socketAddress(for: socketURL.path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard connected == 0 else { throw UnixSocketError.system("connect", errno) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(request)
        data.append(0x0A)
        try writeAll(data, to: descriptor)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                responseData.append(buffer, count: count)
                if responseData.contains(0x0A) { break }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw UnixSocketError.system("read", errno)
            }
        }
        guard let newline = responseData.firstIndex(of: 0x0A) else { throw UnixSocketError.invalidResponse }
        let payload = responseData[..<newline]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IPCResponse.self, from: payload)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, base, remaining)
                if count > 0 {
                    remaining -= count
                    base = base.advanced(by: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw UnixSocketError.system("write", errno)
                }
            }
        }
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCRequest) async -> IPCResponse

    private let socketURL: URL
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "com.olivier.meetingrecorder.socket.accept")
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    public init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        guard descriptor < 0 else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if Darwin.unlink(socketURL.path) != 0, errno != ENOENT {
            throw UnixSocketError.system("unlink stale socket", errno)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno) }
        var (address, length) = try socketAddress(for: socketURL.path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length)
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.system("bind", code)
        }
        guard Darwin.listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.system("listen", code)
        }
        let currentFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)
        chmod(socketURL.path, 0o600)
        descriptor = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
        _ = Darwin.unlink(socketURL.path)
    }

    private func acceptConnections() {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client >= 0 {
                // On Darwin an accepted socket can inherit O_NONBLOCK from the
                // listening socket. The request bytes may not have arrived yet,
                // so make each client blocking and bound both operations instead
                // of treating an initial EAGAIN as a malformed request.
                let clientFlags = fcntl(client, F_GETFL, 0)
                if clientFlags >= 0 {
                    _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
                }
                var timeoutValue = timeval(tv_sec: 30, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                Task { [handler] in
                    await Self.serve(client, handler: handler)
                }
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                return
            }
        }
    }

    private static func serve(_ descriptor: Int32, handler: Handler) async {
        defer { Darwin.close(descriptor) }
        do {
            let data = try readLine(from: descriptor)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let request = try decoder.decode(IPCRequest.self, from: data)
            let response = await handler(request)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var output = try encoder.encode(response)
            output.append(0x0A)
            try writeAll(output, to: descriptor)
        } catch {
            // The client will report a transport error if a malformed request cannot be decoded.
        }
    }

    private static func readLine(from descriptor: Int32) throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while result.count < 1_048_576 {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A { return result }
                result.append(byte)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw UnixSocketError.system("read", errno)
            }
        }
        throw UnixSocketError.invalidResponse
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, base, remaining)
                if count > 0 {
                    remaining -= count
                    base = base.advanced(by: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw UnixSocketError.system("write", errno)
                }
            }
        }
    }
}
