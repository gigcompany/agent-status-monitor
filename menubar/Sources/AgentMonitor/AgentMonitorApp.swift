import SwiftUI

@main
struct AgentMonitorApp: App {
    @StateObject private var store = StatusStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            let summary = store.summary
            HStack(spacing: 3) {
                Image(systemName: summary.symbol)
                if !summary.text.isEmpty {
                    Text(summary.text)
                }
            }
            .onAppear {
                Notifier.shared.start()
                store.startPolling()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
