import AppKit
import Darwin
import Foundation
import MeetingRecorderCore
import MeetingRecorderShared
import UserNotifications

@main
struct MeetingRecorderAgentMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AgentDelegate()
        UNUserNotificationCenter.current().delegate = delegate
        application.delegate = delegate
        application.run()
    }
}

final class AgentDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let paths = RecorderPaths()
    private lazy var logger = FileLogger(fileURL: paths.logFile)
    private var coordinator: RecorderCoordinator?
    private var server: UnixSocketServer?
    private var idleTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private let lifecycleQueue = DispatchQueue(label: "com.olivier.meetingrecorder.lifecycle")
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.log(.info, "MeetingRecorder agent launched, PID \(getpid()).")
        do {
            let coordinator = try RecorderCoordinator(paths: paths)
            self.coordinator = coordinator
            let server = UnixSocketServer(socketURL: paths.socketFile) { request in
                await coordinator.handle(request)
            }
            self.server = server
            installLifecycleObservers()
            Task {
                await coordinator.bootstrap()
                do {
                    try server.start()
                } catch {
                    self.logger.log(.error, "Control socket startup failed: \(error.localizedDescription)")
                    fputs("MeetingRecorder agent failed to start: \(error.localizedDescription)\n", stderr)
                    await MainActor.run { NSApplication.shared.terminate(nil) }
                }
            }
        } catch {
            logger.log(.error, "Agent initialization failed: \(error.localizedDescription)")
            fputs("MeetingRecorder agent initialization failed: \(error.localizedDescription)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress, let coordinator else { return .terminateNow }
        terminationInProgress = true
        logger.log(.info, "MeetingRecorder agent termination requested.")
        Task {
            await coordinator.stopForLifecycleEvent("the recorder application is terminating")
            await MainActor.run {
                self.server?.stop()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        idleTimer?.cancel()
        signalSources.forEach { $0.cancel() }
    }

    private func installLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        installSignal(SIGINT)
        installSignal(SIGTERM)
        let idleTimer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
        idleTimer.schedule(deadline: .now() + 5, repeating: 5)
        idleTimer.setEventHandler { [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            Task {
                if await coordinator.shouldExitAfterIdle(seconds: 20) {
                    self.server?.stop()
                    Darwin.exit(EXIT_SUCCESS)
                }
            }
        }
        self.idleTimer = idleTimer
        idleTimer.resume()
    }

    private func installSignal(_ number: Int32) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: lifecycleQueue)
        source.setEventHandler { [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            Task {
                await coordinator.stopForLifecycleEvent("signal \(number) was received")
                self.server?.stop()
                Darwin.exit(EXIT_SUCCESS)
            }
        }
        signalSources.append(source)
        source.resume()
    }

    @objc private func systemWillSleep() {
        guard let coordinator else { return }
        Task { await coordinator.stopForLifecycleEvent("the Mac is going to sleep") }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let coordinator else { return }
        Task {
            if await coordinator.selectedApplicationPID() == application.processIdentifier {
                await coordinator.stopForLifecycleEvent("the selected application exited")
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
