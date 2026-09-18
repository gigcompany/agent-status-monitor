import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: StatusStore
    @State private var showingSettings = false
    @State private var clearStatus: String?
    @State private var clearStatusTask: Task<Void, Never>?

    private var grouped: [(TaskStatus, [AgentTask])] {
        [TaskStatus.waiting, .working, .failed, .done].compactMap { status in
            let matching = store.visibleTasks.filter { $0.status == status }
            return matching.isEmpty ? nil : (status, matching)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !store.configFound {
                setupPrompt
            } else if store.visibleTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(grouped, id: \.0) { status, items in
                            section(status: status, items: items)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 420)
            }

            if showingSettings {
                Divider()
                settings
            }

            if let clearStatus {
                Divider()
                Text(clearStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }

            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Agents")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            if let error = store.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(error)
            }

            if let updated = store.lastUpdated {
                Text(updated, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func section(status: TaskStatus, items: [AgentTask]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(status.label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            ForEach(items) { task in
                TaskRow(task: task)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("No agent activity")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("in the last \(store.config.lookbackHours)h")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not configured")
                .font(.system(size: 12, weight: .semibold))
            Text("No config file at ~/.agent-status/config.env — run ./install.sh to create one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check again") { store.reloadConfig() }
                .font(.system(size: 11))
        }
        .padding(14)
    }

    /// Read-only on purpose: config.env is the single source of truth, and the
    /// app re-reads it every poll, so edits show up without a restart.
    private var settings: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Backend", store.config.backend)
            row("Reading", backendTarget)
            row("Refresh", "every \(store.config.pollSeconds)s")
            row("Showing", "last \(store.config.lookbackHours)h")
            row("Notify", notifySummary)

            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            HStack(spacing: 12) {
                Button("Edit config") {
                    NSWorkspace.shared.open(AppConfig.configURL)
                }
                Button("Reload") {
                    store.reloadConfig()
                    Task { await store.refresh() }
                }
            }
            .font(.system(size: 11))
            .padding(.top, 4)
        }
        .padding(14)
    }

    /// Hides everything currently shown from this popup - purely local UI
    /// state, no effect on macOS notifications and no effect on the shared
    /// backend, so other machines and viewers are unaffected. A cleared task
    /// that later receives a genuinely new update reappears on its own.
    private func clearAllTasks() {
        let count = store.dismissAllTasks()
        clearStatus = count > 0
            ? "Cleared \(count) task\(count == 1 ? "" : "s")."
            : "Nothing to clear."

        clearStatusTask?.cancel()
        clearStatusTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { clearStatus = nil }
        }
    }

    private var backendTarget: String {
        (try? store.config.makeBackend().describe) ?? "not configured"
    }

    private var notifySummary: String {
        switch (store.config.notifyWaiting, store.config.notifyDone) {
        case (true, true):   return "needs-you + done"
        case (true, false):  return "needs-you only"
        case (false, true):  return "done only"
        case (false, false): return "failures only"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                clearAllTasks()
            } label: {
                Label("Clear", systemImage: "eraser")
            }
            .help("Clear everything from this list")
            .disabled(store.visibleTasks.isEmpty)

            Button {
                showingSettings.toggle()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct TaskRow: View {
    let task: AgentTask
    @State private var hovering = false

    private var tint: Color {
        switch task.status {
        case .waiting: return .orange
        case .working: return task.isStale ? .secondary : .accentColor
        case .done:    return .green
        case .failed:  return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: task.isStale ? "clock.badge.questionmark" : task.status.symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 15)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.task)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = task.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(task.status == .waiting ? .primary : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 5) {
                    Text(task.displayAgent)
                    if let repo = task.repo {
                        Text("·"); Text(repo)
                    }
                    if let progress = task.progressText {
                        Text("·"); Text(progress)
                    }
                    if let age = task.ageDescription {
                        Text("·")
                        Text(age)
                    }
                    if task.isStale {
                        Text("· stale").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .onHover { hovering = $0 }
        .help(task.cwd ?? task.agentId)
    }
}
