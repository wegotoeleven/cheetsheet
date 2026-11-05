import SwiftUI

// @main marks the app's entry point, like `if __name__ == "__main__":` in Python.
@main
struct CheetsheetApp: App {
    // Bridges to an AppKit delegate for things SwiftUI doesn't cover (the overlay).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // @State keeps this object alive for the app's whole lifetime.
    @State private var tracker = AppTracker()
    @AppStorage(AppSettings.showMenuBarIconName) private var showMenuBarIcon = true

    var body: some Scene {
        Window("Cheetsheet", id: "main") {
            ContentView()
                .environment(appDelegate.store) // makes these available to every child view
                .environment(tracker)
        }
        .defaultSize(width: 1000, height: 680)

        MenuBarExtra("Cheetsheet", systemImage: "keyboard", isInserted: $showMenuBarIcon) {
            MenuBarMenu()
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared by the main window and the overlay, so it lives here rather than in a view.
    let store = SheetStore()
    private lazy var overlay = OverlayController(store: store)
    private let holdMonitor = ModifierHoldMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If both icons ended up hidden (e.g. the menu bar icon was ⌘-dragged away), bring the Dock icon back.
        let defaults = UserDefaults.standard
        if !AppSettings.showDockIcon, defaults.object(forKey: AppSettings.showMenuBarIconName) as? Bool == false {
            defaults.set(true, forKey: AppSettings.showDockIconName)
        }
        if !AppSettings.showDockIcon { AppSettings.applyDockIconPolicy() }
        if !Permissions.isTrusted { Permissions.prompt() }
        holdMonitor.onHold = { [weak self] in self?.overlay.show() }
        holdMonitor.onRelease = { [weak self] in self?.overlay.hide() }
        holdMonitor.start()
        Task { await store.refreshLiveBindings() }
    }
}

private struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Cheetsheet") {
            openWindow(id: "main")
            NSApp.activate()
        }
        if Permissions.isTrusted {
            Text("Hold \(AppSettings.trigger.symbol) to show shortcuts")
        } else {
            Button("Allow Accessibility access…") { Permissions.openSettings() }
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Cheetsheet") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
