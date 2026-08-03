import CoreMedia
import Foundation
import MeetingRecorderShared

enum AudioSourceKind { case application, microphone }

private struct AudioLevelAccumulator {
    private var sumOfSquares = 0.0
    private var sampleCount: Int64 = 0
    private var peak = 0.0

    mutating func observe(left: [Float], right: [Float]) {
        for sample in left {
            let amplitude = abs(Double(sample))
            sumOfSquares += amplitude * amplitude
            sampleCount += 1
            peak = max(peak, amplitude)
        }
        for sample in right {
            let amplitude = abs(Double(sample))
            sumOfSquares += amplitude * amplitude
            sampleCount += 1
            peak = max(peak, amplitude)
        }
    }

    var rmsDB: Double? {
        guard sampleCount > 0 else { return nil }
        return Self.decibels(sqrt(sumOfSquares / Double(sampleCount)))
    }

    var peakDB: Double? {
        guard sampleCount > 0 else { return nil }
        return Self.decibels(peak)
    }

    private static func decibels(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 1e-8))
    }
}

private struct SourceTimeline {
    private(set) var baseFrame: Int64 = 0
    private var offset = 0
    private var left: [Float] = []
    private var right: [Float] = []
    private var written: [Bool] = []

    mutating func insert(_ audio: ConvertedAudio, at startFrame: Int64, metrics: inout RecorderMetrics) {
        var sourceOffset = 0
        var destinationFrame = startFrame
        let activeBase = baseFrame + Int64(offset)
        if destinationFrame < activeBase {
            let trim = min(audio.frameCount, Int(activeBase - destinationFrame))
            sourceOffset += trim
            destinationFrame += Int64(trim)
            metrics.lateFrames += Int64(trim)
        }
        guard sourceOffset < audio.frameCount else { return }
        let destinationIndex = offset + Int(destinationFrame - activeBase)
        let count = audio.frameCount - sourceOffset
        ensureCapacity(destinationIndex + count)
        for index in 0..<count {
            let target = destinationIndex + index
            if written[target] { metrics.overlapFrames += 1 }
            left[target] = audio.left[sourceOffset + index]
            right[target] = audio.right[sourceOffset + index]
            written[target] = true
        }
    }

    mutating func read(count: Int, metrics: inout RecorderMetrics) -> (left: [Float], right: [Float]) {
        ensureCapacity(offset + count)
        var outputLeft = [Float](repeating: 0, count: count)
        var outputRight = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let source = offset + index
            if written[source] {
                outputLeft[index] = left[source]
                outputRight[index] = right[source]
            } else {
                metrics.gapFrames += 1
            }
        }
        offset += count
        compactIfNeeded()
        return (outputLeft, outputRight)
    }

    private mutating func ensureCapacity(_ capacity: Int) {
        guard capacity > left.count else { return }
        let additional = capacity - left.count
        left.append(contentsOf: repeatElement(0, count: additional))
        right.append(contentsOf: repeatElement(0, count: additional))
        written.append(contentsOf: repeatElement(false, count: additional))
    }

    private mutating func compactIfNeeded() {
        guard offset >= 48_000 else { return }
        left.removeFirst(offset)
        right.removeFirst(offset)
        written.removeFirst(offset)
        baseFrame += Int64(offset)
        offset = 0
    }
}

final class TimelineMixer: @unchecked Sendable {
    static let sampleRate: Int32 = 48_000
    private let queue = DispatchQueue(label: "com.olivier.meetingrecorder.mixer", qos: .userInitiated)
    private let anchor: CMTime
    private let writer: AACWriter
    private let sourcesWriter: MultiTrackAACWriter
    private let logger: FileLogger
    private let delayFrames: Int64 = 12_000
    private let blockFrames: Int64 = 960
    private var nextOutputFrame: Int64 = 0
    private var application = SourceTimeline()
    private var microphone = SourceTimeline()
    private var timer: DispatchSourceTimer?
    private var metrics = RecorderMetrics()
    private var applicationLevel = AudioLevelAccumulator()
    private var microphoneLevel = AudioLevelAccumulator()
    private var terminalError: Error?
    private var stopped = false

    init(anchor: CMTime, writer: AACWriter, sourcesWriter: MultiTrackAACWriter, logger: FileLogger) {
        self.anchor = anchor
        self.writer = writer
        self.sourcesWriter = sourcesWriter
        self.logger = logger
    }

    func start() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in self?.flushToClock(force: false) }
            self.timer = timer
            timer.resume()
        }
    }

    func insert(_ audio: ConvertedAudio, source: AudioSourceKind) {
        queue.async {
            guard !self.stopped, self.terminalError == nil else { return }
            let startFrame = self.frameIndex(for: audio.presentationTime)
            if startFrame > self.nextOutputFrame + Int64(Self.sampleRate) * 10 {
                self.terminalError = MeetingRecorderError.capture(
                    "Captured audio timestamps are not in the expected host-clock domain."
                )
                return
            }
            switch source {
            case .application: self.application.insert(audio, at: startFrame, metrics: &self.metrics)
            case .microphone: self.microphone.insert(audio, at: startFrame, metrics: &self.metrics)
            }
        }
    }

    func finish() async throws -> RecorderMetrics {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.stopped = true
                self.timer?.cancel()
                self.timer = nil
                self.flushToClock(force: true)
                if let error = self.terminalError {
                    self.writer.cancel()
                    self.sourcesWriter.cancel()
                    continuation.resume(throwing: error)
                    return
                }
                self.metrics.writerBackpressureEvents = self.writer.backpressureEvents + self.sourcesWriter.backpressureEvents
                self.metrics.applicationRMSLevelDB = self.applicationLevel.rmsDB
                self.metrics.applicationPeakLevelDB = self.applicationLevel.peakDB
                self.metrics.microphoneRMSLevelDB = self.microphoneLevel.rmsDB
                self.metrics.microphonePeakLevelDB = self.microphoneLevel.peakDB
                let metrics = self.metrics
                Task {
                    do {
                        try await self.writer.finish()
                        try await self.sourcesWriter.finish()
                        continuation.resume(returning: metrics)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func flushToClock(force: Bool) {
        guard terminalError == nil else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let elapsed = max(0, frameIndex(for: now))
        let target = force ? elapsed : max(0, elapsed - delayFrames)
        while nextOutputFrame + blockFrames <= target {
            let app = application.read(count: Int(blockFrames), metrics: &metrics)
            let mic = microphone.read(count: Int(blockFrames), metrics: &metrics)
            applicationLevel.observe(left: app.left, right: app.right)
            microphoneLevel.observe(left: mic.left, right: mic.right)
            var interleaved = [Float](repeating: 0, count: Int(blockFrames) * 2)
            var applicationInterleaved = [Float](repeating: 0, count: Int(blockFrames) * 2)
            var microphoneInterleaved = [Float](repeating: 0, count: Int(blockFrames) * 2)
            for frame in 0..<Int(blockFrames) {
                let left = 0.5 * app.left[frame] + 0.5 * mic.left[frame]
                let right = 0.5 * app.right[frame] + 0.5 * mic.right[frame]
                if left > 1 || left < -1 { metrics.clippedSamples += 1 }
                if right > 1 || right < -1 { metrics.clippedSamples += 1 }
                interleaved[frame * 2] = min(1, max(-1, left))
                interleaved[frame * 2 + 1] = min(1, max(-1, right))
                applicationInterleaved[frame * 2] = app.left[frame]
                applicationInterleaved[frame * 2 + 1] = app.right[frame]
                microphoneInterleaved[frame * 2] = mic.left[frame]
                microphoneInterleaved[frame * 2 + 1] = mic.right[frame]
            }
            do {
                try writer.append(interleavedSamples: interleaved, startFrame: nextOutputFrame)
                try sourcesWriter.append(
                    application: applicationInterleaved,
                    microphone: microphoneInterleaved,
                    startFrame: nextOutputFrame
                )
            } catch {
                terminalError = error
                logger.log(.error, "Audio writer failed: \(error.localizedDescription)")
                return
            }
            nextOutputFrame += blockFrames
        }
    }

    private func frameIndex(for time: CMTime) -> Int64 {
        let relative = CMTimeSubtract(time, anchor)
        guard relative.isNumeric else { return 0 }
        return Int64((CMTimeGetSeconds(relative) * Double(Self.sampleRate)).rounded())
    }
}
