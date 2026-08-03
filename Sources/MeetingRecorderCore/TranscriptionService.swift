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
    public let rawTranscriptURL: URL?
    public let warning: String?
    public let detectedLanguages: [String]
    public let participants: [String]
}

public typealias MeetingTranscriptionProgressHandler = @Sendable (RecorderTranscriptionProgress) -> Void
public typealias MeetingTranscriptionDiagnosticHandler = @Sendable (String) -> Void

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
    static let chunkDuration: TimeInterval = 60
    private static let meaningfulPeakAmplitude = pow(10.0, -70.0 / 20.0)

    public static func transcribe(
        audioURL: URL,
        modelDirectory: URL,
        model: String = defaultModel,
        language: TranscriptionLanguage = .automatic,
        diarizationEnabled: Bool = true,
        speakerCount: Int? = nil,
        debugEnabled: Bool = false,
        progressHandler: MeetingTranscriptionProgressHandler? = nil,
        diagnosticHandler: MeetingTranscriptionDiagnosticHandler? = nil
    ) async throws -> MeetingTranscriptionOutput {
        let progress = MeetingProgressReporter(handler: progressHandler)
        progress.report(stage: .preparing, fraction: 0, force: true)
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
        diagnosticHandler?("Transcription input opened: audioTracks=\(tracks.count), durationSeconds=\(String(format: "%.3f", duration.seconds)), debug=\(debugEnabled).")

        progress.report(stage: .loadingModel, fraction: 0.03, force: true)
        let config = WhisperKitConfig(
            model: model,
            downloadBase: modelDirectory,
            verbose: false,
            prewarm: true
        )
        let whisper = try await WhisperKit(config)
        diagnosticHandler?("WhisperKit model loaded: model=\(model), language=\(language.rawValue), sequentialWorkers=1.")
        progress.report(stage: .transcribingMeeting, fraction: 0.10, force: true)
        let automaticallyDetectLanguage = language == .automatic
        let options = DecodingOptions(
            language: automaticallyDetectLanguage ? nil : language.rawValue,
            usePrefillPrompt: !automaticallyDetectLanguage,
            detectLanguage: automaticallyDetectLanguage,
            skipSpecialTokens: !debugEnabled,
            wordTimestamps: true,
            concurrentWorkerCount: 1,
            chunkingStrategy: nil
        )
        let meeting: TrackTranscription
        let microphone: TrackTranscription?
        let trackCount = tracks.count
        var detectedLanguages = Set<String>()
        do {
            meeting = try await transcribeTrack(
                tracks[0],
                assetDuration: duration.seconds,
                speaker: .meeting,
                temporaryDirectory: sessionDirectory,
                whisper: whisper,
                options: options,
                trackIndex: 0,
                trackCount: trackCount,
                detectedLanguages: &detectedLanguages,
                progress: progress,
                preserveRawSegments: debugEnabled,
                diagnosticHandler: diagnosticHandler
            )
            if tracks.count == 2 {
                progress.report(
                    stage: .transcribingMicrophone,
                    fraction: transcriptionFraction(completedWork: duration.seconds, totalWork: duration.seconds * 2),
                    languages: detectedLanguages,
                    force: true
                )
                microphone = try await transcribeTrack(
                    tracks[1],
                    assetDuration: duration.seconds,
                    speaker: .you,
                    temporaryDirectory: sessionDirectory,
                    whisper: whisper,
                    options: options,
                    trackIndex: 1,
                    trackCount: trackCount,
                    detectedLanguages: &detectedLanguages,
                    progress: progress,
                    preserveRawSegments: debugEnabled,
                    diagnosticHandler: diagnosticHandler
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
        let participants: [String]
        let applicationTrackSilent = tracks.count == 2 && !meeting.hasMeaningfulAudio
        let microphoneHasMeaningfulAudio = microphone?.hasMeaningfulAudio ?? false
        if applicationTrackSilent {
            diagnosticHandler?("Application track classified as silent; diarization skipped and only microphone speech will be retained.")
            meetingSegments = []
            speakerIdentification = "The application track was effectively silent, so speaker identification was skipped; microphone speech is labelled `You`."
            speakerWarning = "The application audio track was effectively silent. If other participants spoke, select the main browser application for the next recording."
            participants = microphoneHasMeaningfulAudio ? ["You"] : []
        } else if diarizationEnabled {
            do {
                let transcriptionLanguages = detectedLanguages
                progress.report(
                    stage: .identifyingParticipants,
                    fraction: 0.76,
                    languages: transcriptionLanguages,
                    force: true
                )
                let diarization = try await diarizeMeetingTrack(
                    tracks[0],
                    duration: duration,
                    temporaryDirectory: sessionDirectory,
                    modelDirectory: modelDirectory.appendingPathComponent("SpeakerKit", isDirectory: true),
                    speakerCount: speakerCount,
                    progressHandler: { fraction in
                        progress.report(
                            stage: .identifyingParticipants,
                            fraction: 0.76 + (0.20 * fraction),
                            languages: transcriptionLanguages
                        )
                    }
                )
                diagnosticHandler?("Speaker diarization completed: speakers=\(diarization.speakerCount), intervals=\(diarization.intervals.count).")
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
                participants = participantLabels(
                    remoteSpeakerCount: diarization.speakerCount,
                    includeYou: microphoneHasMeaningfulAudio
                )
            } catch {
                diagnosticHandler?("Speaker diarization failed: \(error.localizedDescription)")
                meetingSegments = meeting.segments
                let speechKind = tracks.count == 2 ? "remote speech" : "speech"
                speakerIdentification = "Speaker identification was unavailable; \(speechKind) is labelled `Meeting`. \(error.localizedDescription)"
                speakerWarning = "Transcript saved, but speaker identification failed: \(error.localizedDescription)"
                participants = fallbackParticipantLabels(includeYou: microphoneHasMeaningfulAudio)
            }
        } else {
            meetingSegments = meeting.segments
            speakerIdentification = "Speaker identification is disabled; meeting audio is labelled `Meeting`."
            speakerWarning = nil
            participants = fallbackParticipantLabels(includeYou: microphoneHasMeaningfulAudio)
        }

        let segments = meetingSegments + (microphone?.segments ?? [])
        let sorted = segments.sorted {
            if $0.start == $1.start { return $0.speaker.label < $1.speaker.label }
            return $0.start < $1.start
        }
        let languages = meeting.languages.union(microphone?.languages ?? Set<String>()).sorted()
        detectedLanguages.formUnion(languages)
        let warnings = uniqueWarnings(
            [speakerWarning].compactMap { $0 }
                + coverageWarnings(for: meeting, trackName: "application")
                + coverageWarnings(for: microphone, trackName: "microphone")
        )
        progress.report(
            stage: .writingTranscript,
            fraction: 0.98,
            languages: detectedLanguages,
            participants: participants,
            force: true
        )
        let transcriptURL = transcriptURL(for: audioURL)
        let markdown = renderMarkdown(
            segments: sorted,
            model: model,
            languages: languages,
            speakerIdentification: speakerIdentification,
            hasSeparateMicrophoneTrack: microphone != nil,
            configuredLanguage: language,
            applicationTrackIsSilent: applicationTrackSilent,
            warnings: warnings
        )
        guard let transcriptData = markdown.data(using: .utf8) else {
            throw MeetingRecorderError.io("Unable to encode the transcript as UTF-8.")
        }
        try transcriptData.write(to: transcriptURL, options: .atomic)
        let rawTranscriptURL: URL?
        if debugEnabled {
            let debugURL = Self.rawTranscriptURL(for: audioURL)
            let rawSegments = meeting.rawSegments + (microphone?.rawSegments ?? [])
            let rawMarkdown = renderMarkdown(
                segments: rawSegments.sorted {
                    if $0.start == $1.start { return $0.speaker.label < $1.speaker.label }
                    return $0.start < $1.start
                },
                model: model,
                languages: languages,
                speakerIdentification: "Raw Whisper output before control-token cleanup and speaker diarization.",
                hasSeparateMicrophoneTrack: microphone != nil,
                configuredLanguage: language,
                warnings: ["Debug artifact: control and timestamp tokens are intentionally preserved."],
                sanitizeControlTokens: false
            )
            guard let rawTranscriptData = rawMarkdown.data(using: .utf8) else {
                throw MeetingRecorderError.io("Unable to encode the raw debug transcript as UTF-8.")
            }
            try rawTranscriptData.write(to: debugURL, options: .atomic)
            rawTranscriptURL = debugURL
        } else {
            rawTranscriptURL = nil
        }
        diagnosticHandler?(
            "Transcript output written: clean=\(transcriptURL.lastPathComponent), rawDebug=\(rawTranscriptURL?.lastPathComponent ?? "disabled"), segments=\(sorted.count), participants=\(participants.count)."
        )
        let finalLanguages = detectedLanguages.sorted()
        progress.report(
            stage: .completed,
            fraction: 1,
            languages: Set(finalLanguages),
            participants: participants,
            force: true
        )
        return MeetingTranscriptionOutput(
            transcriptURL: transcriptURL,
            rawTranscriptURL: rawTranscriptURL,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " "),
            detectedLanguages: finalLanguages,
            participants: participants
        )
    }

    public static func renderMarkdown(
        segments: [MeetingTranscriptSegment],
        model: String,
        languages: [String] = [],
        speakerIdentification: String? = nil,
        hasSeparateMicrophoneTrack: Bool = true,
        configuredLanguage: TranscriptionLanguage = .automatic,
        applicationTrackIsSilent: Bool = false,
        warnings: [String] = [],
        sanitizeControlTokens: Bool = true
    ) -> String {
        let speakersDescription: String
        if !sanitizeControlTokens {
            speakersDescription = "`Meeting` and `You` identify the original application and microphone tracks; speaker diarization is intentionally not applied."
        } else if applicationTrackIsSilent {
            speakersDescription = "The application track was silent; only non-silent microphone speech is labelled `You`."
        } else if hasSeparateMicrophoneTrack {
            speakersDescription = "`Speaker 1`, `Speaker 2`, etc. are voices on the meeting track; `You` is the microphone."
        } else {
            speakersDescription = "`Speaker 1`, `Speaker 2`, etc. are diarized voices in this mixed audio file; no separate microphone track was available."
        }
        var lines = [
            sanitizeControlTokens ? "# Meeting transcript" : "# Raw Whisper transcript (debug)",
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
        for warning in warnings {
            lines.append("- Warning: \(warning)")
        }
        lines.append(contentsOf: ["", "## Transcript", ""])
        if segments.isEmpty {
            lines.append("_No speech was detected._")
        } else {
            for segment in segments {
                let text = sanitizeControlTokens
                    ? sanitizedTranscriptText(segment.text)
                    : segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append("[\(formatTimestamp(segment.start))] **\(segment.speaker.label):** \(text)")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func segments(
        from results: [TranscriptionResult],
        speaker: TranscriptSpeaker,
        timeOffset: TimeInterval = 0,
        maximumEnd: TimeInterval,
        sanitizeControlTokens: Bool = true
    ) -> [MeetingTranscriptSegment] {
        results.flatMap(\.segments).compactMap { segment in
            let text = sanitizeControlTokens
                ? sanitizedTranscriptText(segment.text)
                : segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = min(maximumEnd, max(0, timeOffset + TimeInterval(segment.start)))
            let end = min(maximumEnd, max(start, timeOffset + TimeInterval(segment.end)))
            guard start < maximumEnd else { return nil }
            return MeetingTranscriptSegment(
                speaker: speaker,
                start: start,
                end: end,
                text: text
            )
        }
    }

    private struct TrackTranscription {
        var segments: [MeetingTranscriptSegment] = []
        var rawSegments: [MeetingTranscriptSegment] = []
        var words: [MeetingTranscriptWord] = []
        var languages: Set<String> = []
        var peakAmplitude: Float = 0
        var activeFrameCount = 0
        var uncoveredAudibleRanges: [ClosedRange<TimeInterval>] = []

        var hasMeaningfulAudio: Bool {
            Double(peakAmplitude) > meaningfulPeakAmplitude && activeFrameCount >= 2
        }
    }

    private struct ChunkAudioStats {
        let peakAmplitude: Float
        let activeFrameCount: Int

        var containsSpeechLikeAudio: Bool { activeFrameCount >= 2 }
    }

    private static func transcribeTrack(
        _ track: AVAssetTrack,
        assetDuration: TimeInterval,
        speaker: TranscriptSpeaker,
        temporaryDirectory: URL,
        whisper: WhisperKit,
        options: DecodingOptions,
        trackIndex: Int,
        trackCount: Int,
        detectedLanguages: inout Set<String>,
        progress: MeetingProgressReporter,
        preserveRawSegments: Bool,
        diagnosticHandler: MeetingTranscriptionDiagnosticHandler?
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
            let stats: ChunkAudioStats
            do {
                try await exportTrack(
                    track,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: offset, preferredTimescale: 600),
                        duration: CMTime(seconds: duration, preferredTimescale: 600)
                    ),
                    to: temporaryAudio
                )
                let completedBeforeChunk = (Double(trackIndex) * assetDuration) + offset
                let totalWork = assetDuration * Double(trackCount)
                let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: temporaryAudio.path)
                stats = chunkAudioStats(audio)
                transcription.peakAmplitude = max(transcription.peakAmplitude, stats.peakAmplitude)
                transcription.activeFrameCount += stats.activeFrameCount
                diagnosticHandler?(
                    "Transcription chunk prepared: track=\(trackIndex + 1)/\(trackCount), offsetSeconds=\(String(format: "%.3f", offset)), durationSeconds=\(String(format: "%.3f", duration)), peak=\(String(format: "%.6f", stats.peakAmplitude)), activeFrames=\(stats.activeFrameCount)."
                )
                if Double(stats.peakAmplitude) <= meaningfulPeakAmplitude {
                    results = []
                    diagnosticHandler?("Transcription chunk skipped because its measured peak was below the silence threshold.")
                } else {
                    results = try await whisper.transcribe(
                        audioArray: audio,
                        decodeOptions: options,
                        callback: { update in
                            let estimatedChunkProgress = min(duration, Double(update.windowId + 1) * 30)
                            progress.report(
                                stage: speaker == .you ? .transcribingMicrophone : .transcribingMeeting,
                                fraction: transcriptionFraction(
                                    completedWork: completedBeforeChunk + estimatedChunkProgress,
                                    totalWork: totalWork
                                )
                            )
                            return nil
                        }
                    )
                }
                try? FileManager.default.removeItem(at: temporaryAudio)
            } catch {
                try? FileManager.default.removeItem(at: temporaryAudio)
                throw error
            }
            let chunkSegments = segments(
                from: results,
                speaker: speaker,
                timeOffset: offset,
                maximumEnd: assetDuration
            )
            if chunkSegments.isEmpty, stats.containsSpeechLikeAudio {
                transcription.uncoveredAudibleRanges.append(offset...(offset + duration))
            }
            transcription.segments += chunkSegments
            if preserveRawSegments {
                transcription.rawSegments += segments(
                    from: results,
                    speaker: speaker,
                    timeOffset: offset,
                    maximumEnd: assetDuration,
                    sanitizeControlTokens: false
                )
            }
            transcription.words += results.flatMap(\.segments).flatMap { $0.words ?? [] }.compactMap {
                let start = min(assetDuration, max(0, offset + TimeInterval($0.start)))
                let end = min(assetDuration, max(start, offset + TimeInterval($0.end)))
                let text = sanitizedTranscriptText($0.word)
                guard start < assetDuration, !text.isEmpty else { return nil }
                return MeetingTranscriptWord(start: start, end: end, text: text)
            }
            transcription.languages.formUnion(results.map(\.language).filter { !$0.isEmpty })
            diagnosticHandler?(
                "Transcription chunk decoded: cleanedSegments=\(chunkSegments.count), resultLanguages=\(results.map(\.language).filter { !$0.isEmpty }.joined(separator: ","))."
            )
            detectedLanguages.formUnion(transcription.languages)
            offset += duration
            progress.report(
                stage: speaker == .you ? .transcribingMicrophone : .transcribingMeeting,
                fraction: transcriptionFraction(
                    completedWork: (Double(trackIndex) * assetDuration) + offset,
                    totalWork: assetDuration * Double(trackCount)
                ),
                languages: detectedLanguages,
                force: true
            )
        }
        return transcription
    }

    private static func chunkAudioStats(_ audio: [Float]) -> ChunkAudioStats {
        ChunkAudioStats(
            peakAmplitude: audio.reduce(Float.zero) { max($0, abs($1)) },
            activeFrameCount: EnergyVAD().voiceActivity(in: audio).filter { $0 }.count
        )
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
        speakerCount: Int?,
        progressHandler: @escaping @Sendable (Double) -> Void
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
                ),
                progressCallback: { progressHandler($0.fractionCompleted) }
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

    static func rawTranscriptURL(for audioURL: URL) -> URL {
        let cleanURL = transcriptURL(for: audioURL)
        return cleanURL.deletingPathExtension()
            .appendingPathExtension("raw")
            .appendingPathExtension("md")
    }

    static func sanitizedTranscriptText(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"<\|[^>]+\|>"#,
            with: " ",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func transcriptionFraction(completedWork: TimeInterval, totalWork: TimeInterval) -> Double {
        guard totalWork > 0 else { return 0.10 }
        return 0.10 + (0.65 * min(1, max(0, completedWork / totalWork)))
    }

    private static func participantLabels(
        remoteSpeakerCount: Int,
        includeYou: Bool
    ) -> [String] {
        let remote = (0..<remoteSpeakerCount).map { "Speaker \($0 + 1)" }
        return (includeYou ? ["You"] : []) + remote
    }

    private static func fallbackParticipantLabels(includeYou: Bool) -> [String] {
        (includeYou ? ["You"] : []) + ["Meeting"]
    }

    private static func coverageWarnings(
        for transcription: TrackTranscription?,
        trackName: String
    ) -> [String] {
        guard let ranges = transcription?.uncoveredAudibleRanges, !ranges.isEmpty else { return [] }
        let displayed = ranges.prefix(5).map {
            "\(formatTimestamp($0.lowerBound))–\(formatTimestamp($0.upperBound))"
        }
        let additional = ranges.count > displayed.count ? " and \(ranges.count - displayed.count) more range(s)" : ""
        return [
            "Audible \(trackName) audio produced no transcript text at \(displayed.joined(separator: ", "))\(additional). Retranscription was saved, but these ranges should be reviewed."
        ]
    }

    private static func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.compactMap { warning in
            let trimmed = warning.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

private final class MeetingProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: MeetingTranscriptionProgressHandler?
    private var lastFraction: Double = 0
    private var lastReportedAt = Date.distantPast
    private var lastStage: RecorderTranscriptionStage?
    private var detectedLanguages = Set<String>()
    private var identifiedParticipants: [String] = []

    init(handler: MeetingTranscriptionProgressHandler?) {
        self.handler = handler
    }

    func report(
        stage: RecorderTranscriptionStage,
        fraction: Double,
        languages: Set<String> = [],
        participants: [String] = [],
        force: Bool = false
    ) {
        guard let handler else { return }
        lock.lock()
        let now = Date()
        let clampedFraction = min(1, max(lastFraction, fraction))
        let stageChanged = stage != lastStage
        detectedLanguages.formUnion(languages)
        if !participants.isEmpty { identifiedParticipants = participants }
        guard force || stageChanged || now.timeIntervalSince(lastReportedAt) >= 0.25 else {
            lock.unlock()
            return
        }
        lastFraction = clampedFraction
        lastStage = stage
        lastReportedAt = now
        let update = RecorderTranscriptionProgress(
            stage: stage,
            fractionCompleted: clampedFraction,
            detectedLanguages: detectedLanguages.sorted(),
            participants: identifiedParticipants
        )
        lock.unlock()
        handler(update)
    }
}
