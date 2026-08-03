import AVFoundation
import Foundation
import MeetingRecorderShared

public struct RecordingPaths: Sendable {
    public let temporary: URL
    public let final: URL
    public let temporarySources: URL
    public let finalSources: URL
}

public enum RecordingFileManager {
    public static func preferredTranscriptionInput(for requestedURL: URL) -> URL {
        let requestedURL = requestedURL.standardizedFileURL
        guard requestedURL.pathExtension.caseInsensitiveCompare("m4a") == .orderedSame else {
            return requestedURL
        }
        let sourcesURL = requestedURL.deletingPathExtension()
            .appendingPathExtension("sources")
            .appendingPathExtension("mov")
        guard FileManager.default.fileExists(atPath: sourcesURL.path),
              FileManager.default.isReadableFile(atPath: sourcesURL.path) else {
            return requestedURL
        }
        return sourcesURL
    }

    public static func makePaths(outputDirectory: URL, applicationName: String, date: Date = Date()) throws -> RecordingPaths {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw MeetingRecorderError.io("Output directory is not writable: \(outputDirectory.path)")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: date)
        let app = sanitize(applicationName.isEmpty ? "Meeting" : applicationName)
        let base = "\(stamp)_\(app)"
        let sessionDirectory = availableDirectory(in: outputDirectory, baseName: base)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: false)
        let sessionName = sessionDirectory.lastPathComponent
        let final = sessionDirectory.appendingPathComponent(sessionName).appendingPathExtension("m4a")
        let temporary = sessionDirectory.appendingPathComponent(".recording-\(sessionName)-\(UUID().uuidString).mov")
        let finalSources = final.deletingPathExtension()
            .appendingPathExtension("sources")
            .appendingPathExtension("mov")
        let temporarySources = sessionDirectory.appendingPathComponent(".recording-\(sessionName)-\(UUID().uuidString).sources.mov")
        return RecordingPaths(
            temporary: temporary,
            final: final,
            temporarySources: temporarySources,
            finalSources: finalSources
        )
    }

    public static func validate(_ url: URL, expectedAudioTracks: Int = 1) async throws {
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        guard audio.count == expectedAudioTracks else {
            throw MeetingRecorderError.io("Final recording has \(audio.count) audio tracks instead of \(expectedAudioTracks).")
        }
        guard video.isEmpty else { throw MeetingRecorderError.io("Final recording unexpectedly contains video.") }
        guard duration.isNumeric, CMTimeGetSeconds(duration) > 0 else {
            throw MeetingRecorderError.io("Final recording has no playable duration.")
        }
    }

    public static func duration(of url: URL) async throws -> TimeInterval {
        let duration = try await AVURLAsset(url: url).load(.duration)
        guard duration.isNumeric else {
            throw MeetingRecorderError.io("Recording duration is not readable.")
        }
        return CMTimeGetSeconds(duration)
    }

    public static func shouldKeepRecording(
        duration: TimeInterval,
        minimumDuration: TimeInterval = RecorderConfiguration.defaultMinimumDuration
    ) -> Bool {
        duration >= minimumDuration
    }

    public static func discardTemporarySession(files: [URL]) throws {
        let directories = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL })
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        guard directories.count == 1, let directory = directories.first else { return }
        if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public static func finalize(temporary: URL, preferredFinal: URL) async throws -> URL {
        try await validate(temporary)
        let final = FileManager.default.fileExists(atPath: preferredFinal.path)
            ? availableURL(
                in: preferredFinal.deletingLastPathComponent(),
                baseName: preferredFinal.deletingPathExtension().lastPathComponent,
                extension: preferredFinal.pathExtension
            )
            : preferredFinal
        try FileManager.default.moveItem(at: temporary, to: final)
        return final
    }

    public static func finalizePair(
        mixedTemporary: URL,
        mixedFinal: URL,
        sourcesTemporary: URL,
        sourcesFinal: URL
    ) async throws -> (mixed: URL, sources: URL) {
        try await validate(mixedTemporary, expectedAudioTracks: 1)
        try await validate(sourcesTemporary, expectedAudioTracks: 2)
        let preferredPairIsAvailable = !FileManager.default.fileExists(atPath: mixedFinal.path)
            && !FileManager.default.fileExists(atPath: sourcesFinal.path)
        let finalMixed = preferredPairIsAvailable ? mixedFinal : availablePairURL(preferredMixed: mixedFinal)
        let finalSources = finalMixed.deletingPathExtension().appendingPathExtension("sources").appendingPathExtension("mov")
        let exportedMixed = finalMixed.deletingLastPathComponent()
            .appendingPathComponent(".finalizing-\(UUID().uuidString).m4a")
        try await exportAppleM4A(from: mixedTemporary, to: exportedMixed)
        try await validate(exportedMixed, expectedAudioTracks: 1)
        try FileManager.default.moveItem(at: sourcesTemporary, to: finalSources)
        do {
            try FileManager.default.moveItem(at: exportedMixed, to: finalMixed)
            try? FileManager.default.removeItem(at: mixedTemporary)
        } catch {
            try? FileManager.default.moveItem(at: finalSources, to: sourcesTemporary)
            try? FileManager.default.removeItem(at: exportedMixed)
            throw error
        }
        return (finalMixed, finalSources)
    }

    public static func recoverAbandonedRecording(at temporary: URL, expectedAudioTracks: Int = 1) async -> URL? {
        guard FileManager.default.fileExists(atPath: temporary.path) else { return nil }
        do {
            try await validate(temporary, expectedAudioTracks: expectedAudioTracks)
            let rawBase = temporary.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: ".recording-", with: "")
            let withoutUUID = rawBase.replacingOccurrences(
                of: "-[0-9A-Fa-f-]{36}$",
                with: "",
                options: .regularExpression
            )
            let candidate = availableURL(
                in: temporary.deletingLastPathComponent(),
                baseName: "\(withoutUUID)-recovered",
                extension: temporary.pathExtension
            )
            try FileManager.default.moveItem(at: temporary, to: candidate)
            return candidate
        } catch {
            let candidate = availableURL(
                in: temporary.deletingLastPathComponent(),
                baseName: temporary.deletingPathExtension().lastPathComponent + ".failed",
                extension: temporary.pathExtension
            )
            try? FileManager.default.moveItem(at: temporary, to: candidate)
            return nil
        }
    }

    private static func availableURL(in directory: URL, baseName: String, extension ext: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    private static func availableDirectory(in directory: URL, baseName: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    private static func availablePairURL(preferredMixed: URL) -> URL {
        let directory = preferredMixed.deletingLastPathComponent()
        let base = preferredMixed.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let suffix = index == 1 ? "" : "-\(index)"
            let mixed = directory.appendingPathComponent(base + suffix).appendingPathExtension("m4a")
            let sources = directory.appendingPathComponent(base + suffix).appendingPathExtension("sources").appendingPathExtension("mov")
            if !FileManager.default.fileExists(atPath: mixed.path),
               !FileManager.default.fileExists(atPath: sources.path) {
                return mixed
            }
            index += 1
        }
    }

    private static func exportAppleM4A(from input: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingRecorderError.io("The system cannot create an M4A export session.")
        }
        try await exporter.export(to: output, as: .m4a)
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let replaced = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let compact = String(replaced).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return String(compact.trimmingCharacters(in: CharacterSet(charactersIn: "-_ ")).prefix(60))
    }
}
