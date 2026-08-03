import AVFoundation
import CoreMedia
import Foundation
import MeetingRecorderShared
import ScreenCaptureKit

public struct CaptureResult: Sendable {
    public let metrics: RecorderMetrics
}

public final class MeetingCaptureSession: NSObject, @unchecked Sendable {
    public let source: ResolvedCaptureSource
    public let microphoneName: String
    public let microphoneID: String

    private let temporaryOutputURL: URL
    private let temporarySourcesURL: URL
    private let logger: FileLogger
    private let applicationQueue = DispatchQueue(label: "com.olivier.meetingrecorder.capture.application", qos: .userInitiated)
    private let microphoneQueue = DispatchQueue(label: "com.olivier.meetingrecorder.capture.microphone", qos: .userInitiated)
    private let appConverter = SampleBufferAudioConverter()
    private let micConverter = SampleBufferAudioConverter()
    private let observationLock = NSLock()
    private var observedApplication = false
    private var observedMicrophone = false
    private var stream: SCStream?
    private var mixer: TimelineMixer?
    private var failureHandler: (@Sendable (Error) -> Void)?

    public init(
        source: ResolvedCaptureSource,
        temporaryOutputURL: URL,
        temporarySourcesURL: URL,
        logger: FileLogger,
        failureHandler: (@Sendable (Error) -> Void)? = nil
    ) throws {
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw MeetingRecorderError.unavailable("No default microphone is available.")
        }
        self.source = source
        self.temporaryOutputURL = temporaryOutputURL
        self.temporarySourcesURL = temporarySourcesURL
        self.logger = logger
        self.microphoneName = microphone.localizedName
        self.microphoneID = microphone.uniqueID
        self.failureHandler = failureHandler
        super.init()
    }

    public func start() async throws {
        let filter = SCContentFilter(display: source.display, including: [source.application], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphoneID

        let writer = try AACWriter(outputURL: temporaryOutputURL)
        let sourcesWriter: MultiTrackAACWriter
        do {
            sourcesWriter = try MultiTrackAACWriter(outputURL: temporarySourcesURL)
        } catch {
            writer.cancel()
            throw error
        }
        let anchor = CMClockGetTime(CMClockGetHostTimeClock())
        let mixer = TimelineMixer(anchor: anchor, writer: writer, sourcesWriter: sourcesWriter, logger: logger)
        self.mixer = mixer
        mixer.start()

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: applicationQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
            try await stream.startCapture()
            try await waitForInitialBuffers(timeout: 8)
        } catch {
            try? await stream.stopCapture()
            writer.cancel()
            sourcesWriter.cancel()
            self.stream = nil
            self.mixer = nil
            throw error
        }
    }

    public func stop() async throws -> CaptureResult {
        if let stream {
            try await stream.stopCapture()
            self.stream = nil
        }
        guard let mixer else { throw MeetingRecorderError.notRecording }
        self.mixer = nil
        let metrics = try await mixer.finish()
        return CaptureResult(metrics: metrics)
    }

    private func waitForInitialBuffers(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let observed = observationLock.withLock { observedApplication && observedMicrophone }
            if observed { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let missing = observationLock.withLock { () -> String in
            switch (observedApplication, observedMicrophone) {
            case (false, false): return "application audio and microphone"
            case (false, true): return "application audio"
            case (true, false): return "microphone"
            case (true, true): return ""
            }
        }
        throw MeetingRecorderError.capture("Timed out waiting for \(missing) samples. Check permissions and make sure the selected application is producing audio.")
    }
}

extension MeetingCaptureSession: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        do {
            switch outputType {
            case .audio:
                let audio = try appConverter.convert(sampleBuffer)
                observationLock.withLock { observedApplication = true }
                mixer?.insert(audio, source: .application)
            case .microphone:
                let audio = try micConverter.convert(sampleBuffer)
                observationLock.withLock { observedMicrophone = true }
                mixer?.insert(audio, source: .microphone)
            case .screen:
                break
            @unknown default:
                break
            }
        } catch {
            logger.log(.error, "Captured audio processing failed: \(error.localizedDescription)")
            failureHandler?(error)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.log(.error, "ScreenCaptureKit stopped: \(error.localizedDescription)")
        failureHandler?(error)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
