import Foundation
import UserNotifications

public enum RecorderNotificationPermission: Equatable, Sendable {
    case notDetermined
    case enabled
    case denied
}

public enum RecorderNotifications {
    public static func permission() async -> RecorderNotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional, .ephemeral:
            return .enabled
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    @discardableResult
    public static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    public static func requestAuthorizationIfNeeded() async {
        if await permission() == .notDetermined {
            _ = await requestAuthorization()
        }
    }

    public static func transcriptionCompleted(
        transcriptURL: URL,
        warning: String?
    ) async {
        let folderName = transcriptURL.deletingLastPathComponent().lastPathComponent
        let transcriptName = transcriptURL.lastPathComponent == "transcript.md"
            ? folderName
            : transcriptURL.lastPathComponent
        if let warning {
            await deliver(
                title: "Transcription ready with a warning",
                body: "\(transcriptName): \(warning)"
            )
        } else {
            await deliver(
                title: "Transcription ready",
                body: "\(transcriptName) is ready."
            )
        }
    }

    public static func transcriptionFailed(_ error: String) async {
        await deliver(title: "Transcription failed", body: error)
    }

    private static func deliver(title: String, body: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = notificationBody(body)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "meeting-recorder-transcription-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func notificationBody(_ value: String, maximumLength: Int = 240) -> String {
        let singleLine = value
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > maximumLength else { return singleLine }
        return String(singleLine.prefix(max(0, maximumLength - 1))) + "…"
    }
}
