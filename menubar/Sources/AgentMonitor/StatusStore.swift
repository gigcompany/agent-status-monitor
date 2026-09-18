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

    /// Tasks the user has cleared from the popup, and the `updatedAt` each one
    /// had at the moment they cleared it. This only affects what this Mac's
    /// app displays - it never touches the backend, so other machines and
    /// macOS notifications are untouched.
    ///
    /// Nothing is exempt from clearing: a "waiting" task can sit abandoned for
    /// hours (an orphaned session, a permission prompt nobody will ever
    /// answer), and the user should be able to get it off their screen same
    /// as anything else. Recording the timestamp rather than a flat id set is
    /// what makes that safe for live tasks specifically - unlike `done`/
    /// `failed`, a `waiting`/`working` task can receive a genuinely new update
    /// after being cleared (a retried turn, a new question), and that should
    /// reappear rather than stay silenced forever.
    @Published private(set) var dismissedAt: [String: TimeInterval] = [:]
    private let dismissedKey = "dismissedTaskUpdatedAt"

    private var pollTask: Task<Void, Never>?
    private var isFirstLoad = true

    init() {
        seen = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String] ?? [:]
        dismissedAt = UserDefaults.standard.dictionary(forKey: dismissedKey) as? [String: TimeInterval] ?? [:]
        reloadConfig()
    }

    private func isDismissed(_ task: AgentTask) -> Bool {
        guard let clearedAt = dismissedAt[task.id] else { return false }
        let updated = task.updatedAt?.timeIntervalSince1970 ?? 0
        return updated <= clearedAt
    }

    /// What the popup actually shows: everything, minus what the user cleared
    /// and hasn't changed since.
    var visibleTasks: [AgentTask] { tasks.filter { !isDismissed($0) } }

    // The menu bar badge counts what's actually visible, so clearing a task
    // here and the badge disagreeing about whether it still "needs you" can't
    // happen.
    var waitingTasks: [AgentTask] { visibleTasks.filter { $0.status == .waiting } }
    var workingTasks: [AgentTask] { visibleTasks.filter { $0.status == .working && !$0.isStale } }

    /// Hides every currently visible task from the popup, regardless of
    /// status. Any of them that later receives a genuinely new update (a new
    /// `updatedAt`) reappears on its own - clearing silences the current
    /// state, not all future state for that task.
    @discardableResult
    func dismissAllTasks() -> Int {
        var newlyDismissed = 0
        for task in tasks where !isDismissed(task) {
            dismissedAt[task.id] = task.updatedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            newlyDismissed += 1
        }
        guard newlyDismissed > 0 else { return 0 }
        UserDefaults.standard.set(dismissedAt, forKey: dismissedKey)
        return newlyDismissed
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

        // Same for dismissed bookkeeping - once a cleared task expires off the
        // backend entirely, there is nothing left to keep hidden.
        let beforeDismissed = dismissedAt.count
        dismissedAt = dismissedAt.filter { live.contains($0.key) }
        if dismissedAt.count != beforeDismissed {
            UserDefaults.standard.set(dismissedAt, forKey: dismissedKey)
        }

        if changed {
            UserDefaults.standard.set(seen, forKey: seenKey)
        }
    }
}
