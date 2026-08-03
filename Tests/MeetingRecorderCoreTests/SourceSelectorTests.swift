import Foundation
@testable import MeetingRecorderCore
import MeetingRecorderShared
import XCTest

private func app(_ name: String, _ bundle: String, _ pid: Int32) -> ApplicationSnapshot {
    ApplicationSnapshot(name: name, bundleIdentifier: bundle, processID: pid)
}

final class SourceSelectorTests: XCTestCase {
    func testAutomaticSelectionPrefersDedicatedMeetApplication() throws {
        let content = ContentSnapshot(
        applications: [
            app("Google Chrome", "com.google.Chrome", 10),
            app("Google Meet", "com.google.Chrome.app.meet", 20),
        ],
        windows: []
    )
    let result = try ApplicationSourceSelector.select(from: content, selector: .automatic)
        XCTAssertEqual(result.application.processID, 20)
    }

    func testAutomaticSelectionIgnoresSafariAutoFillMeetHelper() throws {
        let meet = app("Google Meet", "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", 1173)
        let content = ContentSnapshot(
            applications: [
                app("AutoFill (Google Meet)", "com.apple.SafariPlatformSupport.Helper", 1426),
                meet,
            ],
            windows: []
        )

        let result = try ApplicationSourceSelector.select(from: content, selector: .automatic)

        XCTAssertEqual(result.application, meet)
    }

    func testPartialMeetNameIgnoresAutoFillHelper() throws {
        let meet = app("Google Meet", "com.google.Chrome.app.meet", 20)
        let content = ContentSnapshot(
            applications: [
                app("AutoFill (Google Meet)", "com.apple.SafariPlatformSupport.Helper", 10),
                meet,
            ],
            windows: []
        )

        let result = try ApplicationSourceSelector.select(from: content, selector: .applicationName("meet"))

        XCTAssertEqual(result.application, meet)
    }

    func testMeetSelectionIgnoresThemeWidgetControlViewService() throws {
        let meet = app("Google Meet", "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", 36714)
        let content = ContentSnapshot(
            applications: [
                meet,
                app(
                    "ThemeWidgetControlViewService (Google Meet)",
                    "com.apple.appkit.xpc.ThemeWidgetControlViewService",
                    36728
                ),
            ],
            windows: []
        )

        let automatic = try ApplicationSourceSelector.select(from: content, selector: .automatic)
        let partial = try ApplicationSourceSelector.select(from: content, selector: .applicationName("meet"))

        XCTAssertEqual(automatic.application, meet)
        XCTAssertEqual(partial.application, meet)
    }

    func testMeetWindowSelectsItsOwnerButWarnsAboutBrowserScope() throws {
        let chrome = app("Google Chrome", "com.google.Chrome", 10)
        let content = ContentSnapshot(
        applications: [chrome],
        windows: [
            WindowSnapshot(
                windowID: 1,
                title: "Google Meet — Weekly 1-on-1",
                ownerName: chrome.name,
                ownerBundleIdentifier: chrome.bundleIdentifier,
                ownerProcessID: chrome.processID,
                isOnScreen: true
            )
        ]
    )
    let result = try ApplicationSourceSelector.select(from: content, selector: .automatic)
        XCTAssertEqual(result.application, chrome)
        XCTAssertEqual(result.warning?.contains("all audio"), true)
    }

    func testAutomaticSelectionRejectsSeveralBrowsers() {
        let content = ContentSnapshot(
        applications: [
            app("Google Chrome", "com.google.Chrome", 10),
            app("Safari", "com.apple.Safari", 20),
        ],
        windows: []
    )
        XCTAssertThrowsError(try ApplicationSourceSelector.select(from: content, selector: .automatic))
    }

    func testExplicitPIDSelectsOneShareableApplication() throws {
        let safari = app("Safari", "com.apple.Safari", 20)
        let content = ContentSnapshot(applications: [safari], windows: [])
        let result = try ApplicationSourceSelector.select(from: content, selector: .processID(20))
        XCTAssertEqual(result.application, safari)
    }

    func testOutputNamesIncludeMixedAndSourcesFiles() throws {
        let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingRecorderCoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let date = Date(timeIntervalSince1970: 1_753_962_600)
    let paths = try RecordingFileManager.makePaths(outputDirectory: directory, applicationName: "Google Meet", date: date)
        let sessionDirectory = paths.final.deletingLastPathComponent()
        XCTAssertEqual(paths.final.pathExtension, "m4a")
        XCTAssertTrue(paths.finalSources.lastPathComponent.hasSuffix(".sources.mov"))
        XCTAssertTrue(paths.temporary.lastPathComponent.hasPrefix(".recording-"))
        XCTAssertTrue(paths.temporarySources.lastPathComponent.hasSuffix(".sources.mov"))
        XCTAssertEqual(paths.temporary.deletingLastPathComponent(), sessionDirectory)
        XCTAssertEqual(paths.finalSources.deletingLastPathComponent(), sessionDirectory)
        XCTAssertEqual(paths.temporarySources.deletingLastPathComponent(), sessionDirectory)
        XCTAssertEqual(paths.final.deletingPathExtension().lastPathComponent, sessionDirectory.lastPathComponent)
    }

    func testEachRecordingGetsACollisionSafeIndividualFolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderFolderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_753_962_600)

        let first = try RecordingFileManager.makePaths(outputDirectory: directory, applicationName: "Google Meet", date: date)
        let second = try RecordingFileManager.makePaths(outputDirectory: directory, applicationName: "Google Meet", date: date)

        let firstFolder = first.final.deletingLastPathComponent()
        let secondFolder = second.final.deletingLastPathComponent()
        XCTAssertNotEqual(firstFolder, secondFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFolder.path))
        XCTAssertTrue(secondFolder.lastPathComponent.hasSuffix("-2"))
    }

    func testShortRecordingPolicyAndFolderCleanup() throws {
        XCTAssertFalse(RecordingFileManager.shouldKeepRecording(duration: 29.999))
        XCTAssertTrue(RecordingFileManager.shouldKeepRecording(duration: 30))
        XCTAssertTrue(RecordingFileManager.shouldKeepRecording(duration: 5, minimumDuration: 5))
        XCTAssertFalse(RecordingFileManager.shouldKeepRecording(duration: 5, minimumDuration: 10))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderDiscardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = try RecordingFileManager.makePaths(outputDirectory: directory, applicationName: "Teams")
        try Data([0]).write(to: paths.temporary)
        try Data([0]).write(to: paths.temporarySources)
        let sessionDirectory = paths.temporary.deletingLastPathComponent()

        try RecordingFileManager.discardTemporarySession(files: [paths.temporary, paths.temporarySources])

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    func testTranscriptMarkdownLabelsAndTimestamps() {
        let markdown = MeetingTranscriber.renderMarkdown(
            segments: [
                MeetingTranscriptSegment(speaker: .remote(0), start: 2, end: 3, text: "Welcome"),
                MeetingTranscriptSegment(speaker: .you, start: 65, end: 67, text: "Thank you"),
            ],
            model: "test-model",
            languages: ["en", "fr"],
            speakerIdentification: "SpeakerKit detected 1 remote speaker."
        )

        XCTAssertTrue(markdown.contains("[00:02] **Speaker 1:** Welcome"))
        XCTAssertTrue(markdown.contains("[01:05] **You:** Thank you"))
        XCTAssertTrue(markdown.contains("English (en), French (fr)"))
        XCTAssertTrue(markdown.contains("automatic multilingual detection"))
    }

    func testMeetingWordsAreGroupedByDiarizedSpeaker() {
        let segments = MeetingTranscriber.attributedMeetingSegments(
            words: [
                MeetingTranscriptWord(start: 0.1, end: 0.4, text: "Hello"),
                MeetingTranscriptWord(start: 0.5, end: 0.9, text: " there"),
                MeetingTranscriptWord(start: 2.1, end: 2.5, text: "Bonjour"),
                MeetingTranscriptWord(start: 2.6, end: 3.0, text: " à tous"),
            ],
            fallback: [],
            intervals: [
                MeetingSpeakerInterval(speakerID: 0, start: 0, end: 2),
                MeetingSpeakerInterval(speakerID: 1, start: 2, end: 4),
            ]
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], MeetingTranscriptSegment(
            speaker: .remote(0), start: 0.1, end: 0.9, text: "Hello there"
        ))
        XCTAssertEqual(segments[1], MeetingTranscriptSegment(
            speaker: .remote(1), start: 2.1, end: 3.0, text: "Bonjour à tous"
        ))
    }

    func testNotificationErrorBodyIsSingleLineAndBounded() {
        let body = RecorderNotifications.notificationBody(
            "Model download failed.\nCheck your internet connection and retry.",
            maximumLength: 40
        )

        XCTAssertFalse(body.contains("\n"))
        XCTAssertLessThanOrEqual(body.count, 40)
        XCTAssertTrue(body.hasSuffix("…"))
    }

    func testTranscriptOutputNameForRecordedSourcesAndOrdinaryAudio() {
        XCTAssertEqual(
            MeetingTranscriber.transcriptURL(for: URL(fileURLWithPath: "/tmp/session/meeting.sources.mov")).path,
            "/tmp/session/transcript.md"
        )
        XCTAssertEqual(
            MeetingTranscriber.transcriptURL(for: URL(fileURLWithPath: "/tmp/interview.m4a")).path,
            "/tmp/interview.transcript.md"
        )
    }

    func testSingleTrackTranscriptExplainsSpeakerScope() {
        let markdown = MeetingTranscriber.renderMarkdown(
            segments: [],
            model: "test-model",
            hasSeparateMicrophoneTrack: false
        )

        XCTAssertTrue(markdown.contains("mixed audio file"))
        XCTAssertTrue(markdown.contains("no separate microphone track"))
    }

    func testAACWritersProducePlayableMixedAndTwoTrackAssets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mixedURL = directory.appendingPathComponent("mixed.mov")
        let sourcesURL = directory.appendingPathComponent("sources.mov")
        let mixedWriter = try AACWriter(outputURL: mixedURL)
        let sourcesWriter = try MultiTrackAACWriter(outputURL: sourcesURL)
        let framesPerBlock = 960
        let silence = [Float](repeating: 0, count: framesPerBlock * 2)
        for block in 0..<50 {
            let start = Int64(block * framesPerBlock)
            try mixedWriter.append(interleavedSamples: silence, startFrame: start)
            try sourcesWriter.append(application: silence, microphone: silence, startFrame: start)
        }
        try await mixedWriter.finish()
        try await sourcesWriter.finish()
        try await RecordingFileManager.validate(mixedURL, expectedAudioTracks: 1)
        try await RecordingFileManager.validate(sourcesURL, expectedAudioTracks: 2)
        let final = try await RecordingFileManager.finalizePair(
            mixedTemporary: mixedURL,
            mixedFinal: directory.appendingPathComponent("Meeting.m4a"),
            sourcesTemporary: sourcesURL,
            sourcesFinal: directory.appendingPathComponent("Meeting.sources.mov")
        )
        try await RecordingFileManager.validate(final.mixed, expectedAudioTracks: 1)
        try await RecordingFileManager.validate(final.sources, expectedAudioTracks: 2)
        XCTAssertEqual(final.mixed.pathExtension, "m4a")
        XCTAssertTrue(final.sources.lastPathComponent.hasSuffix(".sources.mov"))
    }
}
