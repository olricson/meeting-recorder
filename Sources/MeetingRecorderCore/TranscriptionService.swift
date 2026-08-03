import AVFoundation
import Foundation
import MeetingRecorderShared
import SpeakerKit
import WhisperKit

public enum TranscriptSpeaker: Equatable, Sendable {
    case meeting
    case remote(Int)
    case you

    public var label: String {
        switch self {
        case .meeting: return "Meeting"
        case .remote(let identifier): return "Speaker \(identifier + 1)"
        case .you: return "You"
        }
    }

    fileprivate var temporaryFileComponent: String {
        switch self {
        case .meeting, .remote: return "meeting"
        case .you: return "you"
        }
    }
}

public struct MeetingTranscriptSegment: Equatable, Sendable {
    public let speaker: TranscriptSpeaker
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(speaker: TranscriptSpeaker, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct MeetingTranscriptionOutput: Sendable {
    public let transcriptURL: URL
    public let warning: String?
}

struct MeetingTranscriptWord: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct MeetingSpeakerInterval: Equatable, Sendable {
    let speakerID: Int
    let start: TimeInterval
    let end: TimeInterval
}

public enum MeetingTranscriber {
    public static let defaultModel = RecorderConfiguration.defaultTranscriptionModel
    static let chunkDuration: TimeInterval = 10 * 60

    public static func transcribe(
        audioURL: URL,
        modelDirectory: URL,
        model: String = defaultModel,
        language: TranscriptionLanguage = .automatic,
        diarizationEnabled: Bool = true,
        speakerCount: Int? = nil
    ) async throws -> MeetingTranscriptionOutput {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let sessionDirectory = audioURL.deletingLastPathComponent()
        let asset = AVURLAsset(url: audioURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1 || tracks.count == 2 else {
            throw MeetingRecorderError.io(
                "The transcription input must contain one audio track, or two tracks for separate meeting and microphone audio."
            )
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            throw MeetingRecorderError.io("The transcription source has no readable duration.")
        }

        let config = WhisperKitConfig(
            model: model,
            downloadBase: modelDirectory,
            verbose: false,
            prewarm: true
        )
        let whisper = try await WhisperKit(config)
        let automaticallyDetectLanguage = language == .automatic
        let options = DecodingOptions(
            language: automaticallyDetectLanguage ? nil : language.rawValue,
            usePrefillPrompt: !automaticallyDetectLanguage,
            detectLanguage: automaticallyDetectLanguage,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let meeting: TrackTranscription
        let microphone: TrackTranscription?
        do {
            meeting = try await transcribeTrack(
                tracks[0],
                assetDuration: duration.seconds,
                speaker: .meeting,
                temporaryDirectory: sessionDirectory,
                whisper: whisper,
                options: options
            )
            if tracks.count == 2 {
                microphone = try await transcribeTrack(
                    tracks[1],
                    assetDuration: duration.seconds,
                    speaker: .you,
                    temporaryDirectory: sessionDirectory,
                    whisper: whisper,
                    options: options
                )
            } else {
                microphone = nil
            }
            await whisper.unloadModels()
        } catch {
            await whisper.unloadModels()
            throw error
        }

        let speakerIdentification: String
        let speakerWarning: String?
        let meetingSegments: [MeetingTranscriptSegment]
        if diarizationEnabled {
            do {
                let diarization = try await diarizeMeetingTrack(
                    tracks[0],
                    duration: duration,
                    temporaryDirectory: sessionDirectory,
                    modelDirectory: modelDirectory.appendingPathComponent("SpeakerKit", isDirectory: true),
                    speakerCount: speakerCount
                )
                meetingSegments = attributedMeetingSegments(
                    words: meeting.words,
                    fallback: meeting.segments,
                    intervals: diarization.intervals
                )
                let speakerKind = tracks.count == 2 ? "remote speaker" : "speaker"
                speakerIdentification = diarization.speakerCount == 1
                    ? "SpeakerKit detected 1 \(speakerKind)."
                    : "SpeakerKit detected \(diarization.speakerCount) \(speakerKind)s."
                speakerWarning = nil
            } catch {
                meetingSegments = meeting.segments
                let speechKind = tracks.count == 2 ? "remote speech" : "speech"
                speakerIdentification = "Speaker identification was unavailable; \(speechKind) is labelled `Meeting`. \(error.localizedDescription)"
                speakerWarning = "Transcript saved, but speaker identification failed: \(error.localizedDescription)"
            }
        } else {
            meetingSegments = meeting.segments
            speakerIdentification = "Speaker identification is disabled; meeting audio is labelled `Meeting`."
            speakerWarning = nil
        }

        let segments = meetingSegments + (microphone?.segments ?? [])
        let sorted = segments.sorted {
            if $0.start == $1.start { return $0.speaker.label < $1.speaker.label }
            return $0.start < $1.start
        }
        let languages = meeting.languages.union(microphone?.languages ?? Set<String>()).sorted()
        let transcriptURL = transcriptURL(for: audioURL)
        let markdown = renderMarkdown(
            segments: sorted,
            model: model,
            languages: languages,
            speakerIdentification: speakerIdentification,
            hasSeparateMicrophoneTrack: microphone != nil,
            configuredLanguage: language
        )
        guard let transcriptData = markdown.data(using: .utf8) else {
            throw MeetingRecorderError.io("Unable to encode the transcript as UTF-8.")
        }
        try transcriptData.write(to: transcriptURL, options: .atomic)
        return MeetingTranscriptionOutput(transcriptURL: transcriptURL, warning: speakerWarning)
    }

    public static func renderMarkdown(
        segments: [MeetingTranscriptSegment],
        model: String,
        languages: [String] = [],
        speakerIdentification: String? = nil,
        hasSeparateMicrophoneTrack: Bool = true,
        configuredLanguage: TranscriptionLanguage = .automatic
    ) -> String {
        let speakersDescription = hasSeparateMicrophoneTrack
            ? "`Speaker 1`, `Speaker 2`, etc. are voices on the meeting track; `You` is the microphone."
            : "`Speaker 1`, `Speaker 2`, etc. are diarized voices in this mixed audio file; no separate microphone track was available."
        var lines = [
            "# Meeting transcript",
            "",
            "- Model: `\(model)`",
            "- Language: \(languageModeDescription(configuredLanguage))",
            "- Speakers: \(speakersDescription)",
        ]
        if !languages.isEmpty {
            lines.append("- Detected languages: \(languages.map(languageDisplayName).joined(separator: ", "))")
        }
        if let speakerIdentification {
            lines.append("- Speaker identification: \(speakerIdentification)")
        }
        lines.append(contentsOf: ["", "## Transcript", ""])
        if segments.isEmpty {
            lines.append("_No speech was detected._")
        } else {
            for segment in segments {
                lines.append("[\(formatTimestamp(segment.start))] **\(segment.speaker.label):** \(segment.text)")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func segments(
        from results: [TranscriptionResult],
        speaker: TranscriptSpeaker,
        timeOffset: TimeInterval = 0
    ) -> [MeetingTranscriptSegment] {
        results.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return MeetingTranscriptSegment(
                speaker: speaker,
                start: timeOffset + TimeInterval(segment.start),
                end: timeOffset + TimeInterval(segment.end),
                text: text
            )
        }
    }

    private struct TrackTranscription {
        var segments: [MeetingTranscriptSegment] = []
        var words: [MeetingTranscriptWord] = []
        var languages: Set<String> = []
    }

    private static func transcribeTrack(
        _ track: AVAssetTrack,
        assetDuration: TimeInterval,
        speaker: TranscriptSpeaker,
        temporaryDirectory: URL,
        whisper: WhisperKit,
        options: DecodingOptions
    ) async throws -> TrackTranscription {
        var transcription = TrackTranscription()
        var offset: TimeInterval = 0
        while offset < assetDuration {
            try Task.checkCancellation()
            let duration = min(chunkDuration, assetDuration - offset)
            guard duration > 0.001 else { break }
            let temporaryAudio = temporaryDirectory.appendingPathComponent(
                ".transcription-\(speaker.temporaryFileComponent)-\(UUID().uuidString).m4a"
            )
            let results: [TranscriptionResult]
            do {
                try await exportTrack(
                    track,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: offset, preferredTimescale: 600),
                        duration: CMTime(seconds: duration, preferredTimescale: 600)
                    ),
                    to: temporaryAudio
                )
                results = try await whisper.transcribe(audioPath: temporaryAudio.path, decodeOptions: options)
                try? FileManager.default.removeItem(at: temporaryAudio)
            } catch {
                try? FileManager.default.removeItem(at: temporaryAudio)
                throw error
            }
            transcription.segments += segments(from: results, speaker: speaker, timeOffset: offset)
            transcription.words += results.flatMap(\.segments).flatMap { $0.words ?? [] }.map {
                MeetingTranscriptWord(
                    start: offset + TimeInterval($0.start),
                    end: offset + TimeInterval($0.end),
                    text: $0.word
                )
            }
            transcription.languages.formUnion(results.map(\.language).filter { !$0.isEmpty })
            offset += duration
        }
        return transcription
    }

    static func attributedMeetingSegments(
        words: [MeetingTranscriptWord],
        fallback: [MeetingTranscriptSegment],
        intervals: [MeetingSpeakerInterval]
    ) -> [MeetingTranscriptSegment] {
        guard !words.isEmpty, !intervals.isEmpty else { return fallback }
        var attributed: [MeetingTranscriptSegment] = []
        var currentSpeaker: TranscriptSpeaker?
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0
        var currentText = ""

        func appendCurrent() {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let currentSpeaker, !text.isEmpty else { return }
            attributed.append(MeetingTranscriptSegment(
                speaker: currentSpeaker,
                start: currentStart,
                end: currentEnd,
                text: text
            ))
        }

        for word in words {
            let speaker = matchingSpeaker(for: word, intervals: intervals).map(TranscriptSpeaker.remote) ?? .meeting
            let startsNewSegment = currentSpeaker != speaker || word.start - currentEnd > 2
            if startsNewSegment {
                appendCurrent()
                currentSpeaker = speaker
                currentStart = word.start
                currentText = word.text
            } else {
                currentText += word.text
            }
            currentEnd = word.end
        }
        appendCurrent()
        return attributed.isEmpty ? fallback : attributed
    }

    private static func matchingSpeaker(
        for word: MeetingTranscriptWord,
        intervals: [MeetingSpeakerInterval]
    ) -> Int? {
        var best: (speakerID: Int, overlap: TimeInterval)?
        for interval in intervals {
            if interval.end < word.start { continue }
            if interval.start > word.end { break }
            let overlap = max(0, min(word.end, interval.end) - max(word.start, interval.start))
            if best == nil || overlap > best!.overlap {
                best = (interval.speakerID, overlap)
            }
        }
        if let best, best.overlap > 0 { return best.speakerID }

        let midpoint = (word.start + word.end) / 2
        return intervals.min {
            distance(from: midpoint, to: $0) < distance(from: midpoint, to: $1)
        }.flatMap { distance(from: midpoint, to: $0) <= 0.75 ? $0.speakerID : nil }
    }

    private static func distance(from time: TimeInterval, to interval: MeetingSpeakerInterval) -> TimeInterval {
        if time < interval.start { return interval.start - time }
        if time > interval.end { return time - interval.end }
        return 0
    }

    private struct MeetingDiarization {
        let speakerCount: Int
        let intervals: [MeetingSpeakerInterval]
    }

    private static func diarizeMeetingTrack(
        _ track: AVAssetTrack,
        duration: CMTime,
        temporaryDirectory: URL,
        modelDirectory: URL,
        speakerCount: Int?
    ) async throws -> MeetingDiarization {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let temporaryAudio = temporaryDirectory.appendingPathComponent(
            ".diarization-meeting-\(UUID().uuidString).m4a"
        )
        defer { try? FileManager.default.removeItem(at: temporaryAudio) }
        try await exportTrack(track, timeRange: CMTimeRange(start: .zero, duration: duration), to: temporaryAudio)
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: temporaryAudio.path)
        let config = PyannoteConfig(downloadBase: modelDirectory.path, verbose: false)
        let speakerKit = try await SpeakerKit(config)
        let result: DiarizationResult
        do {
            result = try await speakerKit.diarize(
                audioArray: audio,
                options: PyannoteDiarizationOptions(
                    numberOfSpeakers: speakerCount,
                    useExclusiveReconciliation: true
                )
            )
            await speakerKit.unloadModels()
        } catch {
            await speakerKit.unloadModels()
            throw error
        }
        return MeetingDiarization(
            speakerCount: result.speakerCount,
            intervals: result.segments.compactMap { segment in
                guard let speakerID = segment.speaker.speakerId else { return nil }
                return MeetingSpeakerInterval(
                    speakerID: speakerID,
                    start: TimeInterval(segment.startTime),
                    end: TimeInterval(segment.endTime)
                )
            }
        )
    }

    private static func exportTrack(_ track: AVAssetTrack, timeRange: CMTimeRange, to output: URL) async throws {
        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MeetingRecorderError.io("Unable to create a temporary transcription track.")
        }
        try destination.insertTimeRange(
            timeRange,
            of: track,
            at: .zero
        )
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingRecorderError.io("Unable to create a temporary transcription export.")
        }
        try await exporter.export(to: output, as: .m4a)
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    static func transcriptURL(for audioURL: URL) -> URL {
        let directory = audioURL.deletingLastPathComponent()
        if audioURL.lastPathComponent.hasSuffix(".sources.mov") {
            return directory.appendingPathComponent("transcript.md")
        }
        return directory.appendingPathComponent(
            audioURL.deletingPathExtension().lastPathComponent + ".transcript.md"
        )
    }

    private static func languageDisplayName(_ code: String) -> String {
        switch code.lowercased() {
        case "en", "english": return "English (en)"
        case "fr", "french": return "French (fr)"
        default: return code
        }
    }

    private static func languageModeDescription(_ language: TranscriptionLanguage) -> String {
        switch language {
        case .automatic: return "automatic multilingual detection; English and French are supported."
        case .english: return "forced English (en)."
        case .french: return "forced French (fr)."
        }
    }
}
