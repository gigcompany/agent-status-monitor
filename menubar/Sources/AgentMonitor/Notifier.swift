import Foundation
import OSLog
import UserNotifications

let appLog = Logger(subsystem: "com.gofloaters.agentmonitor", category: "monitor")

/// Delivers desktop notifications.
///
/// Prefers UNUserNotificationCenter, but a SwiftPM-built bundle that is not
/// notarized is refused notification authorization on current macOS
/// ("Notifications are not allowed for this application"). When that happens we
/// fall back to `osascript`, which is always permitted. If the app is ever
/// notarized the native path takes over on its own with no code change.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var useNativeCenter = false

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.useNativeCenter = granted
            if granted {
                appLog.notice("using native notifications")
            } else {
                appLog.notice(
                    "native notifications unavailable (\(error?.localizedDescription ?? "denied", privacy: .public)); using osascript fallback"
                )
            }
        }
    }

    func notify(title: String, body: String, id: String = UUID().uuidString) {
        if useNativeCenter {
            postNative(title: title, body: body, id: id)
        } else {
            postViaAppleScript(title: title, body: body)
        }
    }

    private func postNative(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            appLog.error("native delivery failed: \(error.localizedDescription, privacy: .public)")
            // Don't silently drop the alert - the whole point is to reach the user.
            self?.postViaAppleScript(title: title, body: body)
        }
    }

    /// Title and body are passed as `argv`, never interpolated into the script
    /// source, so agent-authored text cannot inject AppleScript.
    private func postViaAppleScript(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "display notification (item 1 of argv) with title (item 2 of argv) sound name \"Ping\"",
            "-e", "end run",
            body.isEmpty ? " " : body,
            title,
        ]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        process.terminationHandler = { finished in
            if finished.terminationStatus == 0 {
                appLog.notice("notification delivered via osascript")
            } else {
                appLog.error("osascript exited \(finished.terminationStatus, privacy: .public)")
            }
        }

        do {
            try process.run()
        } catch {
            appLog.error("osascript notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A menu bar app counts as active, so banners need this to appear at all.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
