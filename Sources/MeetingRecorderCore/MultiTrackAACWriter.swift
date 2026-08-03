import AVFoundation
import CoreMedia
import Foundation
import MeetingRecorderShared

final class MultiTrackAACWriter {
    private let writer: AVAssetWriter
    private let applicationInput: AVAssetWriterInput
    private let microphoneInput: AVAssetWriterInput
    private let formatDescription: CMAudioFormatDescription
    private var pending: [(application: CMSampleBuffer, microphone: CMSampleBuffer, frames: Int)] = []
    private var pendingFrames = 0
    private(set) var backpressureEvents: Int64 = 0

    init(outputURL: URL) throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw MeetingRecorderError.io("Unable to create the source-track PCM format description (\(status)).")
        }
        formatDescription = description
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        applicationInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        applicationInput.expectsMediaDataInRealTime = true
        microphoneInput.expectsMediaDataInRealTime = true
        applicationInput.metadata = [Self.titleMetadata("Meeting application")]
        microphoneInput.metadata = [Self.titleMetadata("Microphone (you)")]
        guard writer.canAdd(applicationInput), writer.canAdd(microphoneInput) else {
            throw MeetingRecorderError.io(
                "AVAssetWriter rejected the two source audio tracks (media types: \(writer.availableMediaTypes); settings supported: \(writer.canApply(outputSettings: settings, forMediaType: .audio)))."
            )
        }
        writer.add(applicationInput)
        writer.add(microphoneInput)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        guard writer.startWriting() else {
            throw MeetingRecorderError.io("Unable to start the source-track writer: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(application: [Float], microphone: [Float], startFrame: Int64) throws {
        let frameCount = application.count / 2
        guard frameCount > 0, microphone.count == application.count else { return }
        let appBuffer = try makePCMSampleBuffer(
            interleavedSamples: application,
            startFrame: startFrame,
            formatDescription: formatDescription
        )
        let micBuffer = try makePCMSampleBuffer(
            interleavedSamples: microphone,
            startFrame: startFrame,
            formatDescription: formatDescription
        )
        pending.append((appBuffer, micBuffer, frameCount))
        pendingFrames += frameCount
        try flushPending()
        if pendingFrames > 96_000 {
            throw MeetingRecorderError.io("The source-track encoder remained backpressured for more than two seconds.")
        }
    }

    func finish() async throws {
        let deadline = Date().addingTimeInterval(2)
        while !pending.isEmpty, Date() < deadline {
            try flushPending()
            if !pending.isEmpty { usleep(10_000) }
        }
        guard pending.isEmpty else { throw MeetingRecorderError.io("The source-track encoder did not drain before finalization.") }
        applicationInput.markAsFinished()
        microphoneInput.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else {
            throw MeetingRecorderError.io("Unable to finalize source tracks: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    func cancel() { writer.cancelWriting() }

    private func flushPending() throws {
        while applicationInput.isReadyForMoreMediaData,
              microphoneInput.isReadyForMoreMediaData,
              let first = pending.first {
            guard applicationInput.append(first.application), microphoneInput.append(first.microphone) else {
                throw MeetingRecorderError.io("Unable to append source tracks: \(writer.error?.localizedDescription ?? "unknown error")")
            }
            pending.removeFirst()
            pendingFrames -= first.frames
        }
        if !pending.isEmpty { backpressureEvents += 1 }
    }

    private static func titleMetadata(_ title: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        return item
    }
}
