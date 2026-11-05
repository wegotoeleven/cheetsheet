import AppKit
import SwiftUI

/// Owns the floating overlay panel: works out what's in front (the app, plus
/// anything like tmux or vim running inside it), sizes the panel to fit,
/// and centres it on the screen the mouse is on.
final class OverlayController {
    private let store: SheetStore
    private lazy var panel = makePanel()
    private lazy var host = NSHostingView(rootView: OverlayView(content: .placeholder))
    private var loadTask: Task<Void, Never>?
    /// Menus rarely change, so keep each app's shortcuts for a minute.
    private var cache: [pid_t: (groups: [MenuGroup], time: Date)] = [:]

    init(store: SheetStore) {
        self.store = store
    }

    func show() {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown app"
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var content = OverlayContent(
            breadcrumb: [appName],
            appIcon: app?.icon,
            state: .loading,
            triggerSymbol: AppSettings.trigger.symbol,
            // Roughly how many compact rows fit in 80% of the screen height.
            maxRowsPerColumn: max(8, Int((visible.height * 0.8 - 90) / 27)),
            maxContentWidth: visible.width * 0.9 - 40  // minus the panel's padding
        )

        guard Permissions.isTrusted, let pid = app?.processIdentifier else {
            content.state = .needsPermission
            display(content, in: visible)
            return
        }

        let cached = cache[pid].flatMap { Date().timeIntervalSince($0.time) < 60 ? $0.groups : nil }
        // Only show the spinner when reading menus will take a while; the title alone is instant.
        if cached == nil { display(content, in: visible) }

        loadTask?.cancel()
        loadTask = Task {
            // Re-check tmux's bindings at the same time (throttled, so usually instant).
            async let liveRefresh: Void = store.refreshLiveBindings()
            // Read the window title (and menus, if not cached) off the main thread.
            let (menus, title) = await Task.detached {
                (cached ?? MenuReader.shortcuts(forPID: pid), MenuReader.focusedWindowTitle(forPID: pid))
            }.value
            await liveRefresh
            guard !Task.isCancelled else { return }
            cache[pid] = (menus, Date())

            var breadcrumb = [appName]
            let resolved = layers(app: app, appName: appName, menus: menus, title: title, breadcrumb: &breadcrumb)
            var finished = content
            finished.breadcrumb = breadcrumb
            finished.state = .layers(resolved)
            // In a terminal where nothing was detected, show the title we read so it's clear why.
            let isTerminal = app?.bundleIdentifier.map(Cheatsheet.terminalBundleIDs.contains) ?? false
            if isTerminal, breadcrumb.count == 1 {
                finished.hint = "Nothing detected in the window title “\(title ?? "")”. Settings → Terminals can fix this."
            }
            display(finished, in: visible)
        }
    }

    func hide() {
        loadTask?.cancel()
        panel.orderOut(nil)
    }

    /// Builds the layers to show, in order: programs spotted in a terminal's title (vim, then
    /// tmux), the app itself (menus plus config bindings), sheets attached to the app, then
    /// sheets shown everywhere. Also fills in the breadcrumb, outermost first.
    private func layers(app: NSRunningApplication?, appName: String, menus: [MenuGroup],
                        title: String?, breadcrumb: inout [String]) -> [OverlayLayer] {
        let bundleID = app?.bundleIdentifier
        func layer(_ sheet: Cheatsheet) -> OverlayLayer {
            OverlayLayer(name: sheet.name, groups: sheet.shortcutGroups(live: store.live[sheet.id]))
        }

        let inner = store.sheets
            .filter { $0.matchesTerminal(bundleID: bundleID, windowTitle: title) }
            .sorted { ($0.layer ?? 0) > ($1.layer ?? 0) }
        var layers = inner.map(layer)
        breadcrumb += inner.reversed().map(\.name)

        if !(AppSettings.hideHostMenus && !inner.isEmpty) {
            let config = bundleID.flatMap { store.appConfigs[$0] }
            layers.append(OverlayLayer(name: appName, groups: config?.merged(into: menus) ?? menus))
        }
        layers += store.sheets.filter { $0.attaches(toBundleID: bundleID) }.map(layer)
        layers += store.sheets.filter(\.showsEverywhere).map(layer)
        return layers
    }

    private func display(_ content: OverlayContent, in visible: CGRect) {
        host.rootView = OverlayView(content: content)
        var size = host.fittingSize
        size.width = min(size.width, visible.width * 0.95)
        size.height = min(size.height, visible.height * 0.95)
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        // A non-activating panel floats above everything without stealing focus
        // from the app you're looking up shortcuts for.
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Accept the mouse so the overlay can be scrolled; a click still dismisses it.
        panel.ignoresMouseEvents = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
        return panel
    }
}
