import Foundation
import os
import Darwin

public final class FileLogger: @unchecked Sendable {
    public enum Level: String { case info, warning, error }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.olivier.meetingrecorder.log")
    private let systemLogger = Logger(subsystem: "com.olivier.meetingrecorder", category: "recorder")
    private let maxSize = 5 * 1_024 * 1_024
    private var supplementalFileURL: URL?

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func setSupplementalFile(_ url: URL?) {
        queue.sync { supplementalFileURL = url?.standardizedFileURL }
    }

    public func flush() {
        queue.sync {}
    }

    public func log(_ level: Level, _ message: String) {
        switch level {
        case .info: systemLogger.info("\(message, privacy: .public)")
        case .warning: systemLogger.warning("\(message, privacy: .public)")
        case .error: systemLogger.error("\(message, privacy: .public)")
        }
        queue.async { [self, fileURL, maxSize] in
            let formatter = ISO8601DateFormatter()
            let sanitized = message.replacingOccurrences(of: "\n", with: " ")
            let line = "\(formatter.string(from: Date())) [\(level.rawValue.uppercased())] \(sanitized)\n"
            try? Self.write(line, to: fileURL, rotatingAt: maxSize)
            if let supplementalFileURL {
                try? Self.write(line, to: supplementalFileURL, rotatingAt: nil)
            }
        }
    }

    private static func write(_ line: String, to url: URL, rotatingAt maxSize: Int?) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let maxSize,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size >= maxSize {
            try rotate(url)
        }
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        let data = Data(line.utf8)
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: written), bytes.count - written)
                guard result > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
    }

    private static func rotate(_ url: URL) throws {
        let manager = FileManager.default
        let third = URL(fileURLWithPath: url.path + ".3")
        let second = URL(fileURLWithPath: url.path + ".2")
        let first = URL(fileURLWithPath: url.path + ".1")
        if manager.fileExists(atPath: third.path) { try manager.removeItem(at: third) }
        if manager.fileExists(atPath: second.path) { try manager.moveItem(at: second, to: third) }
        if manager.fileExists(atPath: first.path) { try manager.moveItem(at: first, to: second) }
        if manager.fileExists(atPath: url.path) { try manager.moveItem(at: url, to: first) }
    }
}
