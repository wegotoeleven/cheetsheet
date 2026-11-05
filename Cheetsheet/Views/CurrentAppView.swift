import SwiftUI

/// Shows the menu shortcuts of the last app you used before switching to Cheetsheet.
struct CurrentAppView: View {
    @Environment(AppTracker.self) private var tracker
    @State private var groups: [MenuGroup] = []
    @State private var isLoading = false

    var body: some View {
        content
            .navigationTitle(tracker.lastApp?.localizedName ?? "Current app")
            // Re-runs whenever the tracked app changes; cancelled automatically if it changes again.
            .task(id: tracker.lastApp?.processIdentifier) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !Permissions.isTrusted {
            ContentUnavailableView {
                Label("Accessibility access needed", systemImage: "lock")
            } description: {
                Text("Cheetsheet reads shortcuts from other apps' menus. Allow it in Privacy & Security → Accessibility, then reopen Cheetsheet.")
            } actions: {
                Button("Open System Settings") { Permissions.openSettings() }
            }
        } else if tracker.lastApp == nil {
            ContentUnavailableView("No app yet", systemImage: "macwindow",
                                   description: Text("Switch to another app and back to see its shortcuts."))
        } else if isLoading {
            ProgressView()
        } else if groups.isEmpty {
            ContentUnavailableView("No shortcuts found", systemImage: "keyboard",
                                   description: Text("This app's menus have no keyboard shortcuts."))
        } else {
            ScrollView {
                MasonryLayout {
                    ForEach(groups) { group in
                        ShortcutCard(title: group.title) {
                            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                ShortcutRow(title: item.title, keys: item.keys)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private func load() async {
        guard Permissions.isTrusted, let pid = tracker.lastApp?.processIdentifier else { return }
        isLoading = true
        groups = await Task.detached { MenuReader.shortcuts(forPID: pid) }.value
        isLoading = false
    }
}
