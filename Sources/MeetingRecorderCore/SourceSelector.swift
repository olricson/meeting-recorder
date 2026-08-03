import Foundation
import MeetingRecorderShared

public struct SourceSelectionResult: Equatable, Sendable {
    public var application: ApplicationSnapshot
    public var warning: String?

    public init(application: ApplicationSnapshot, warning: String? = nil) {
        self.application = application
        self.warning = warning
    }
}

public enum ApplicationSourceSelector {
    private static let recorderBundleID = "com.olivier.meetingrecorder"

    public static func select(from content: ContentSnapshot, selector: SourceSelector) throws -> SourceSelectionResult {
        let applications = content.applications
            .filter { !$0.bundleIdentifier.hasPrefix(recorderBundleID) }
            .sorted { ($0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending) }

        switch selector {
        case .automatic:
            return try automaticSelection(applications: applications, windows: content.windows)
        case .processID(let processID):
            guard let match = applications.first(where: { $0.processID == processID }) else {
                throw MeetingRecorderError.sourceNotFound("No shareable application has PID \(processID). Run `meeting-recorder list`.")
            }
            return result(for: match)
        case .bundleIdentifier(let bundleIdentifier):
            let matches = applications.filter { $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
            return try requireUnique(matches, description: "bundle identifier \(bundleIdentifier)")
        case .applicationName(let name):
            let exact = applications.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if !exact.isEmpty { return try requireUnique(exact, description: "application name \(name)") }
            let partial = applications.filter { $0.name.localizedCaseInsensitiveContains(name) }
            let nonHelpers = partial.filter { !isCaptureHelper($0) }
            return try requireUnique(nonHelpers.isEmpty ? partial : nonHelpers, description: "application name containing \(name)")
        }
    }

    private static func automaticSelection(
        applications: [ApplicationSnapshot],
        windows: [WindowSnapshot]
    ) throws -> SourceSelectionResult {
        let chromeMeetApplications = applications.filter(isChromeMeetApplication)
        let mainChromeApplications = applications.filter(isMainChrome)
        if !chromeMeetApplications.isEmpty, mainChromeApplications.count == 1 {
            return SourceSelectionResult(
                application: mainChromeApplications[0],
                warning: "A Google Meet Chrome app was found, but macOS may attribute its audio to the main Google Chrome process. Recording all Chrome audio instead."
            )
        }

        let exactMeet = applications.filter {
            $0.name.caseInsensitiveCompare("Google Meet") == .orderedSame
                && !isCaptureHelper($0)
                && !isChromeMeetApplication($0)
        }
        if exactMeet.count == 1 { return result(for: exactMeet[0]) }
        if exactMeet.count > 1 {
            throw ambiguous(exactMeet, context: "Several exact Google Meet applications are available")
        }

        let namedMeet = applications.filter {
            isDedicatedMeetApplication($0) && !isChromeMeetApplication($0)
        }
        if namedMeet.count == 1 { return result(for: namedMeet[0]) }
        if namedMeet.count > 1 {
            throw ambiguous(namedMeet, context: "Several Google Meet applications are available")
        }

        let meetOwnerPIDs = Set(windows.compactMap { window -> Int32? in
            guard isMeetWindowTitle(window.title) else { return nil }
            return window.ownerProcessID
        })
        let windowOwners = applications.filter {
            meetOwnerPIDs.contains($0.processID) && !isChromeMeetApplication($0)
        }
        if windowOwners.count == 1 { return result(for: windowOwners[0]) }
        if windowOwners.count > 1 {
            throw ambiguous(windowOwners, context: "Meet-looking windows belong to several applications")
        }

        let browsers = applications.filter(isSupportedBrowser)
        if browsers.count == 1 { return result(for: browsers[0]) }
        if browsers.count > 1 {
            throw ambiguous(browsers, context: "Several supported browsers are available")
        }
        let chromeMeetHint = chromeMeetApplications.isEmpty
            ? ""
            : " A Chrome-installed Google Meet app was found, but it is not selected automatically because its audio can be silent; launch the main Google Chrome application or explicitly select the app at your own risk."
        throw MeetingRecorderError.sourceNotFound(
            "No Google Meet, Chrome, or Safari application could be selected.\(chromeMeetHint) Run `meeting-recorder list`, then use --app, --bundle-id, or --pid."
        )
    }

    private static func requireUnique(_ matches: [ApplicationSnapshot], description: String) throws -> SourceSelectionResult {
        guard let first = matches.first else {
            throw MeetingRecorderError.sourceNotFound("No shareable application matches \(description). Run `meeting-recorder list`.")
        }
        guard matches.count == 1 else { throw ambiguous(matches, context: "More than one application matches \(description)") }
        return result(for: first)
    }

    private static func result(for application: ApplicationSnapshot) -> SourceSelectionResult {
        let warning = isSupportedBrowser(application)
            ? "ScreenCaptureKit records all audio from \(application.name), including its other tabs and windows."
            : nil
        return SourceSelectionResult(application: application, warning: warning)
    }

    private static func ambiguous(_ applications: [ApplicationSnapshot], context: String) -> MeetingRecorderError {
        let candidates = applications
            .map { "\($0.name) (\($0.bundleIdentifier), PID \($0.processID))" }
            .joined(separator: "; ")
        return .ambiguousSource("\(context): \(candidates). Select one with --app, --bundle-id, or --pid.")
    }

    private static func isMeetWindowTitle(_ title: String) -> Bool {
        let normalized = title.lowercased()
        return normalized.contains("google meet") || normalized.contains("meet.google.com") || normalized.hasPrefix("meet –") || normalized.hasPrefix("meet -")
    }

    private static func isDedicatedMeetApplication(_ application: ApplicationSnapshot) -> Bool {
        application.name.localizedCaseInsensitiveContains("Google Meet")
            && !isCaptureHelper(application)
    }

    private static func isCaptureHelper(_ application: ApplicationSnapshot) -> Bool {
        let bundle = application.bundleIdentifier.lowercased()
        let name = application.name.lowercased()
        return name.hasPrefix("autofill (")
            || name.contains("viewservice")
            || bundle.contains("safariplatformsupport.helper")
            || bundle.hasPrefix("com.apple.appkit.xpc.")
            || bundle.hasSuffix(".helper")
            || bundle.contains(".helper.")
    }

    private static func isSupportedBrowser(_ application: ApplicationSnapshot) -> Bool {
        guard !isCaptureHelper(application) else { return false }
        let bundle = application.bundleIdentifier.lowercased()
        let name = application.name.lowercased()
        return bundle == "com.google.chrome"
            || bundle == "com.apple.safari"
            || bundle.hasPrefix("com.apple.safari.")
            || name == "google chrome"
            || name == "safari"
    }

    private static func isMainChrome(_ application: ApplicationSnapshot) -> Bool {
        application.bundleIdentifier.caseInsensitiveCompare("com.google.Chrome") == .orderedSame
            || application.name.caseInsensitiveCompare("Google Chrome") == .orderedSame
    }

    private static func isChromeMeetApplication(_ application: ApplicationSnapshot) -> Bool {
        application.bundleIdentifier.lowercased().hasPrefix("com.google.chrome.app.")
            && application.name.localizedCaseInsensitiveContains("Google Meet")
            && !isCaptureHelper(application)
    }
}
