import Foundation
import os

public final class FileLogger: @unchecked Sendable {
    public enum Level: String { case info, warning, error }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.olivier.meetingrecorder.log")
    private let systemLogger = Logger(subsystem: "com.olivier.meetingrecorder", category: "recorder")
    private let maxSize = 5 * 1_024 * 1_024

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func log(_ level: Level, _ message: String) {
        switch level {
        case .info: systemLogger.info("\(message, privacy: .public)")
        case .warning: systemLogger.warning("\(message, privacy: .public)")
        case .error: systemLogger.error("\(message, privacy: .public)")
        }
        queue.async { [fileURL, maxSize] in
            do {
                let manager = FileManager.default
                try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= maxSize {
                    try Self.rotate(fileURL)
                }
                let formatter = ISO8601DateFormatter()
                let sanitized = message.replacingOccurrences(of: "\n", with: " ")
                let line = "\(formatter.string(from: Date())) [\(level.rawValue.uppercased())] \(sanitized)\n"
                let data = Data(line.utf8)
                if manager.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: fileURL, options: .atomic)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                }
            } catch {
                // The unified logger above remains available if file logging fails.
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
