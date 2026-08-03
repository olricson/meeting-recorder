import Foundation
import MeetingRecorderShared
import UserNotifications

public enum RecorderNotificationPermission: Equatable, Sendable {
    case notDetermined
    case enabled
    case denied
}

public enum RecorderNotifications {
    private static let progressIdentifierPrefix = "meeting-recorder-transcription-progress-"

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
        warning: String?,
        sessionID: UUID?
    ) async {
        clearTranscriptionProgress(sessionID: sessionID)
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

    public static func transcriptionFailed(_ error: String, sessionID: UUID?) async {
        clearTranscriptionProgress(sessionID: sessionID)
        await deliver(title: "Transcription failed", body: error)
    }

    public static func transcriptionProgress(
        _ progress: RecorderTranscriptionProgress,
        sessionID: UUID,
        sourceName: String?
    ) async {
        guard progress.stage != .completed, progress.stage != .failed else { return }
        let percent = Int((progress.fractionCompleted * 100).rounded())
        var details = [transcriptionStageLabel(progress.stage)]
        if !progress.detectedLanguages.isEmpty {
            details.append("Language: \(progress.detectedLanguages.map(languageDisplayName).joined(separator: ", "))")
        }
        if !progress.participants.isEmpty {
            details.append("Participants: \(progress.participants.joined(separator: ", "))")
        }
        let source = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        await deliver(
            identifier: progressIdentifier(sessionID),
            title: "Transcribing — \(percent)%",
            body: ([source].compactMap { $0 } + details).joined(separator: " • "),
            sound: false,
            replacingDeliveredNotification: true
        )
    }

    private static func deliver(
        identifier: String = "meeting-recorder-transcription-\(UUID().uuidString)",
        title: String,
        body: String,
        sound: Bool = true,
        replacingDeliveredNotification: Bool = false
    ) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = notificationBody(body)
        if sound { content.sound = .default }
        let center = UNUserNotificationCenter.current()
        if replacingDeliveredNotification {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    private static func clearTranscriptionProgress(sessionID: UUID?) {
        guard let sessionID else { return }
        let identifier = progressIdentifier(sessionID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private static func progressIdentifier(_ sessionID: UUID) -> String {
        progressIdentifierPrefix + sessionID.uuidString
    }

    static func transcriptionStageLabel(_ stage: RecorderTranscriptionStage) -> String {
        switch stage {
        case .preparing: return "Preparing audio"
        case .loadingModel: return "Loading transcription model"
        case .transcribingMeeting: return "Transcribing meeting audio"
        case .transcribingMicrophone: return "Transcribing microphone audio"
        case .identifyingParticipants: return "Identifying participants"
        case .writingTranscript: return "Writing transcript"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private static func languageDisplayName(_ code: String) -> String {
        switch code.lowercased() {
        case "en", "english": return "English"
        case "fr", "french": return "French"
        default: return code
        }
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
