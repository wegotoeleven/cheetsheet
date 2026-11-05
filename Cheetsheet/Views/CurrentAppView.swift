import SwiftUI

/// Shows the shortcuts of the last app you used before switching to Cheetsheet:
/// its menus, plus bindings from its config where Cheetsheet can read it.
struct CurrentAppView: View {
    @Environment(AppTracker.self) private var tracker
    @Environment(SheetStore.self) private var store
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
                                ShortcutRow(title: item.title, note: item.note, keys: item.keys,
                                            replaced: item.replaced, alsoWorks: item.alsoWorks)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private func load() async {
        guard Permissions.isTrusted, let app = tracker.lastApp else { return }
        let pid = app.processIdentifier
        isLoading = true
        async let refresh: Void = store.refreshLiveBindings()
        let menus = await Task.detached { MenuReader.shortcuts(forPID: pid) }.value
        await refresh
        // Switched to another app meanwhile: its own load will fill this in.
        guard !Task.isCancelled else { return }
        // Add bindings from the app's config, if Cheetsheet can read it.
        let config = app.bundleIdentifier.flatMap { store.appConfigs[$0] }
        groups = config?.merged(into: menus) ?? menus
        isLoading = false
    }
}
