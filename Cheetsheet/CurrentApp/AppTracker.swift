import AppKit
import Observation

/// Remembers the last app that was in front, other than Cheetsheet itself,
/// so the main window's "Current app" page can show that app's shortcuts.
@Observable
final class AppTracker {
    private(set) var lastApp: NSRunningApplication?

    init() {
        update(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.update(app) }
        }
    }

    private func update(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastApp = app
    }
}
