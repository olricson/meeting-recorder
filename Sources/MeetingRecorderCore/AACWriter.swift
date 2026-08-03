import AVFoundation
import CoreMedia
import Foundation
import MeetingRecorderShared

final class AACWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let formatDescription: CMAudioFormatDescription
    private var pending: [(buffer: CMSampleBuffer, frames: Int)] = []
    private var pendingFrames = 0
    private(set) var backpressureEvents: Int64 = 0
    private let maximumPendingFrames = 96_000

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
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard formatStatus == noErr, let description else {
            throw MeetingRecorderError.io("Unable to create the PCM format description (\(formatStatus)).")
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
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw MeetingRecorderError.io(
                "AVAssetWriter rejected the AAC audio input (media types: \(writer.availableMediaTypes); settings supported: \(writer.canApply(outputSettings: settings, forMediaType: .audio)))."
            )
        }
        writer.add(input)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        guard writer.startWriting() else {
            throw MeetingRecorderError.io("Unable to start the mixed audio writer: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(interleavedSamples: [Float], startFrame: Int64) throws {
        let frameCount = interleavedSamples.count / 2
        guard frameCount > 0 else { return }
        let sampleBuffer = try makePCMSampleBuffer(
            interleavedSamples: interleavedSamples,
            startFrame: startFrame,
            formatDescription: formatDescription
        )
        pending.append((sampleBuffer, frameCount))
        pendingFrames += frameCount
        try flushPending()
        if pendingFrames > maximumPendingFrames {
            throw MeetingRecorderError.io("The audio encoder remained backpressured for more than two seconds.")
        }
    }

    func finish() async throws {
        let deadline = Date().addingTimeInterval(2)
        while !pending.isEmpty, Date() < deadline {
            try flushPending()
            if !pending.isEmpty { usleep(10_000) }
        }
        guard pending.isEmpty else {
            throw MeetingRecorderError.io("The audio encoder did not drain before finalization.")
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw MeetingRecorderError.io("Unable to finalize the recording: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    func cancel() { writer.cancelWriting() }

    private func flushPending() throws {
        while input.isReadyForMoreMediaData, let first = pending.first {
            guard input.append(first.buffer) else {
                throw MeetingRecorderError.io("Unable to append audio: \(writer.error?.localizedDescription ?? "unknown writer error")")
            }
            pending.removeFirst()
            pendingFrames -= first.frames
        }
        if !pending.isEmpty { backpressureEvents += 1 }
    }

}

func makePCMSampleBuffer(
    interleavedSamples: [Float],
    startFrame: Int64,
    formatDescription: CMAudioFormatDescription
) throws -> CMSampleBuffer {
        let byteCount = interleavedSamples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw MeetingRecorderError.io("Unable to allocate an audio block buffer (\(status)).")
        }
        status = interleavedSamples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else {
            throw MeetingRecorderError.io("Unable to populate an audio block buffer (\(status)).")
        }

        let frameCount = interleavedSamples.count / 2
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: startFrame, timescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size * 2
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw MeetingRecorderError.io("Unable to create an audio sample buffer (\(status)).")
        }
    return sampleBuffer
}
