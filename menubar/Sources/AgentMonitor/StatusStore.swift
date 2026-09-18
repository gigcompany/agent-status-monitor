import Foundation
import SwiftUI

@MainActor
final class StatusStore: ObservableObject {
    @Published var tasks: [AgentTask] = []
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    @Published var config = AppConfig()
    @Published var configFound = false

    /// taskId -> the status we last told the user about. Persisted so restarting
    /// the app does not re-notify for everything already on the board.
    private var seen: [String: String] = [:]
    private let seenKey = "seenStatuses"

    /// Finished tasks the user has cleared from the popup. This only affects
    /// what this Mac's app displays - it never touches the backend, so other
    /// machines and macOS notifications are untouched.
    @Published private(set) var dismissedIds: Set<String> = []
    private let dismissedKey = "dismissedTaskIds"

    private var pollTask: Task<Void, Never>?
    private var isFirstLoad = true

    init() {
        seen = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String] ?? [:]
        dismissedIds = Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
        reloadConfig()
    }

    var waitingTasks: [AgentTask] { tasks.filter { $0.status == .waiting } }
    var workingTasks: [AgentTask] { tasks.filter { $0.status == .working && !$0.isStale } }

    /// What the popup actually shows: live tasks always, finished ones only
    /// until the user clears them.
    var visibleTasks: [AgentTask] { tasks.filter { !dismissedIds.contains($0.id) } }

    /// Hides every currently finished task from the popup. Live tasks
    /// (working/waiting) are never dismissable - they still need attention or
    /// are still in progress, so hiding them would just be confusing.
    @discardableResult
    func dismissFinishedTasks() -> Int {
        let toDismiss = tasks
            .filter { $0.status == .done || $0.status == .failed }
            .map(\.id)
        let newlyDismissed = Set(toDismiss).subtracting(dismissedIds)
        guard !newlyDismissed.isEmpty else { return 0 }

        dismissedIds.formUnion(newlyDismissed)
        UserDefaults.standard.set(Array(dismissedIds), forKey: dismissedKey)
        return newlyDismissed.count
    }

    /// What the menu bar icon shows at a glance.
    var summary: (symbol: String, text: String, attention: Bool) {
        if !configFound { return ("exclamationmark.circle", "setup", true) }
        if lastError != nil && tasks.isEmpty { return ("bolt.horizontal.circle", "", false) }
        if !waitingTasks.isEmpty { return ("questionmark.circle.fill", "\(waitingTasks.count)", true) }
        if !workingTasks.isEmpty { return ("circle.dotted", "\(workingTasks.count)", false) }
        return ("checkmark.circle", "", false)
    }

    func reloadConfig() {
        if let loaded = AppConfig.load() {
            config = loaded
            configFound = true
        } else {
            configFound = false
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = max(1, self?.config.pollSeconds ?? 5)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        // Re-read the config every cycle so editing config.env takes effect
        // without restarting the app.
        reloadConfig()
        guard configFound else { return }

        do {
            let backend = try config.makeBackend()
            let since = Date().addingTimeInterval(-Double(config.lookbackHours) * 3600)
            let fetched = try await backend.fetchTasks(since: since)

            let sorted = fetched.sorted { lhs, rhs in
                if lhs.status.priority != rhs.status.priority {
                    return lhs.status.priority < rhs.status.priority
                }
                return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }

            diffAndNotify(sorted)
            tasks = sorted
            lastError = nil
            lastUpdated = Date()
            isFirstLoad = false
        } catch {
            lastError = error.localizedDescription
            appLog.debug("refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func diffAndNotify(_ fresh: [AgentTask]) {
        var changed = false

        for task in fresh {
            let previous = seen[task.id]
            defer {
                if previous != task.status.rawValue {
                    seen[task.id] = task.status.rawValue
                    changed = true
                }
            }

            // The first load only takes a baseline; otherwise launching the app
            // would fire one notification per historical task.
            guard !isFirstLoad, previous != task.status.rawValue else { continue }

            switch task.status {
            case .waiting where config.notifyWaiting:
                Notifier.shared.notify(
                    title: "\(task.displayAgent) needs you",
                    body: task.question ?? task.task,
                    id: "waiting-\(task.id)"
                )
            case .done where config.notifyDone:
                Notifier.shared.notify(
                    title: "\(task.displayAgent) finished",
                    body: task.detail ?? task.task,
                    id: "done-\(task.id)"
                )
            case .failed:
                Notifier.shared.notify(
                    title: "\(task.displayAgent) failed",
                    body: task.detail ?? task.task,
                    id: "failed-\(task.id)"
                )
            default:
                break
            }
        }

        // Forget bookkeeping for tasks that aged out of the window.
        let live = Set(fresh.map(\.id))
        let before = seen.count
        seen = seen.filter { live.contains($0.key) }
        if seen.count != before { changed = true }

        // Same for dismissed ids - once a cleared task expires off the backend
        // entirely, there is nothing left to keep hidden.
        let beforeDismissed = dismissedIds.count
        dismissedIds.formIntersection(live)
        if dismissedIds.count != beforeDismissed {
            UserDefaults.standard.set(Array(dismissedIds), forKey: dismissedKey)
        }

        if changed {
            UserDefaults.standard.set(seen, forKey: seenKey)
        }
    }
}
