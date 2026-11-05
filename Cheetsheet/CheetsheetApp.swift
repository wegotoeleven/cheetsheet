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
                // Lets the Dock icon follow the window in "While a window is open" mode.
                .onAppear { AppSettings.windowOpened() }
                .modifier(RegistersWindowOpener())
                .onDisappear { AppSettings.windowClosed() }
        }
        .defaultSize(width: 1000, height: 680)

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarMenu()
        } label: {
            Image(nsImage: menuBarIcon)
        }

        Settings {
            SettingsView()
        }
    }
}

/// The ⌘ squircle, drawn larger than MenuBarExtra's default so it matches other menu bar icons.
/// As a template image, macOS colours it to suit light and dark menu bars.
private let menuBarIcon: NSImage = {
    let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    let image = NSImage(systemSymbolName: "command.square.fill", accessibilityDescription: "Cheetsheet")!
        .withSymbolConfiguration(config)!
    image.isTemplate = true
    return image
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared by the main window and the overlay, so it lives here rather than in a view.
    let store = SheetStore()
    private lazy var overlay = OverlayController(store: store)
    private let holdMonitor = ModifierHoldMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Give the main window a moment to open first, so the Dock icon doesn't
        // vanish and reappear during launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppSettings.applyDockIconPolicy() }
        // The menu bar icon can be turned off outside Settings, by ⌘-dragging it out of the
        // menu bar. Any settings change re-checks the Dock icon; it's a no-op when nothing changed.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppSettings.applyDockIconPolicy() }
        }
        if !Permissions.isTrusted { Permissions.prompt() }
        holdMonitor.onHold = { [weak self] in self?.overlay.show() }
        holdMonitor.onRelease = { [weak self] in self?.overlay.hide() }
        holdMonitor.start()
        Task { await store.refreshLiveBindings() }
    }

    /// SwiftUI quits apps whose only window closes. Cheetsheet keeps running for the
    /// overlay and menu bar icon, so it only quits from the Quit command.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let open = MainWindow.open else { return true }
        open()
        return false
    }
}

/// Lets AppKit code open the main window. SwiftUI's `openWindow` only exists inside views,
/// so the main window hands it over here the first time it appears.
enum MainWindow {
    static var open: (() -> Void)?
}

private struct RegistersWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { MainWindow.open = { openWindow(id: "main") } }
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
