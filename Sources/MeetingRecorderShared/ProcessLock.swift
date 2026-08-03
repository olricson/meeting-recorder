import Darwin
import Foundation

public final class ProcessLock: @unchecked Sendable {
    private let url: URL
    private var descriptor: Int32 = -1

    public init(url: URL) { self.url = url }
    deinit { unlock() }

    public func tryLock() throws -> Bool {
        guard descriptor < 0 else { return true }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw MeetingRecorderError.io("Unable to open recorder lock: \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            if errno == EWOULDBLOCK { return false }
            throw MeetingRecorderError.io("Unable to lock recorder state: \(String(cString: strerror(errno)))")
        }
        ftruncate(fd, 0)
        let pidText = "\(getpid())\n"
        _ = pidText.withCString { Darwin.write(fd, $0, strlen($0)) }
        descriptor = fd
        return true
    }

    public func unlock() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}

public final class StateStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.olivier.meetingrecorder.state")

    public init(url: URL) { self.url = url }

    public func load() -> RecorderState {
        queue.sync {
            (try? AtomicJSONStore.load(RecorderState.self, from: url)) ?? RecorderState()
        }
    }

    public func save(_ state: RecorderState) throws {
        try queue.sync { try AtomicJSONStore.save(state, to: url) }
    }
}
