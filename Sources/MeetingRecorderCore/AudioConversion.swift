import AVFoundation
import CoreMedia
import Foundation
import MeetingRecorderShared

struct ConvertedAudio {
    let left: [Float]
    let right: [Float]
    let presentationTime: CMTime

    var frameCount: Int { min(left.count, right.count) }
}

final class SampleBufferAudioConverter {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ sampleBuffer: CMSampleBuffer) throws -> ConvertedAudio {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            throw MeetingRecorderError.capture("ScreenCaptureKit produced an invalid audio buffer.")
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let inputFormat = AVAudioFormat(streamDescription: streamDescription) else {
            throw MeetingRecorderError.capture("Unable to determine the captured audio format.")
        }
        let inputFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrames) else {
            throw MeetingRecorderError.capture("Unable to allocate a captured audio buffer.")
        }
        inputBuffer.frameLength = inputFrames
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(inputFrames),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw MeetingRecorderError.capture("Unable to read captured PCM audio (\(copyStatus)).")
        }

        if converter == nil || sourceFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw MeetingRecorderError.capture("Unable to convert \(inputFormat) to the recorder format.")
            }
            if inputFormat.channelCount == 1 { newConverter.channelMap = [0, 0] }
            newConverter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            newConverter.primeMethod = .none
            converter = newConverter
            sourceFormat = inputFormat
        }
        guard let converter else { throw MeetingRecorderError.capture("Audio converter is unavailable.") }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputFrames) * ratio) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw MeetingRecorderError.capture("Unable to allocate the mixed audio buffer.")
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error else {
            throw MeetingRecorderError.capture("Audio conversion failed: \(conversionError?.localizedDescription ?? "unknown error")")
        }
        guard let channels = outputBuffer.floatChannelData else {
            throw MeetingRecorderError.capture("Converted audio is not Float32 PCM.")
        }
        let count = Int(outputBuffer.frameLength)
        return ConvertedAudio(
            left: Array(UnsafeBufferPointer(start: channels[0], count: count)),
            right: Array(UnsafeBufferPointer(start: channels[1], count: count)),
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }
}
