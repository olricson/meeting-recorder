import Foundation
import MeetingRecorderShared
import ScreenCaptureKit

public struct ResolvedCaptureSource {
    public let application: SCRunningApplication
    public let display: SCDisplay
    public let snapshot: ApplicationSnapshot
    public let warning: String?
}

public enum ShareableContentService {
    public static func fetch() async throws -> (SCShareableContent, ContentSnapshot) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let applications = content.applications.map {
            ApplicationSnapshot(name: $0.applicationName, bundleIdentifier: $0.bundleIdentifier, processID: $0.processID)
        }
        let windows = content.windows.map { window in
            WindowSnapshot(
                windowID: window.windowID,
                title: window.title ?? "",
                ownerName: window.owningApplication?.applicationName,
                ownerBundleIdentifier: window.owningApplication?.bundleIdentifier,
                ownerProcessID: window.owningApplication?.processID,
                isOnScreen: window.isOnScreen
            )
        }
        return (content, ContentSnapshot(applications: applications, windows: windows))
    }

    public static func snapshot() async throws -> ContentSnapshot {
        try await fetch().1
    }

    public static func resolve(_ selector: SourceSelector) async throws -> ResolvedCaptureSource {
        let (content, snapshot) = try await fetch()
        let selection = try ApplicationSourceSelector.select(from: snapshot, selector: selector)
        guard let application = content.applications.first(where: { $0.processID == selection.application.processID }) else {
            throw MeetingRecorderError.sourceNotFound("The selected application exited before capture began.")
        }
        guard let display = preferredDisplay(for: application, in: content) else {
            throw MeetingRecorderError.unavailable("No shareable display is available for the ScreenCaptureKit filter.")
        }
        return ResolvedCaptureSource(
            application: application,
            display: display,
            snapshot: selection.application,
            warning: selection.warning
        )
    }

    private static func preferredDisplay(for application: SCRunningApplication, in content: SCShareableContent) -> SCDisplay? {
        let windows = content.windows.filter { $0.owningApplication?.processID == application.processID && $0.isOnScreen }
        for window in windows {
            if let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) {
                return display
            }
        }
        return content.displays.first(where: { CGMainDisplayID() == $0.displayID }) ?? content.displays.first
    }
}
