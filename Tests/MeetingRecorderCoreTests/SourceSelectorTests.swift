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
        XCTAssertEqual(paths.final.pathExtension, "m4a")
        XCTAssertTrue(paths.finalSources.lastPathComponent.hasSuffix(".sources.mov"))
        XCTAssertTrue(paths.temporary.lastPathComponent.hasPrefix(".recording-"))
        XCTAssertTrue(paths.temporarySources.lastPathComponent.hasSuffix(".sources.mov"))
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
