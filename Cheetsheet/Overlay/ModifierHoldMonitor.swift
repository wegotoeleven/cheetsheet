import AppKit

/// Watches the keyboard system-wide and calls `onHold` once the trigger modifier
/// (from Settings) has been held on its own for the set delay, then `onRelease` when it's let go.
///
/// Using the modifier with another key (⌘C) or a click cancels the hold, so normal
/// shortcuts never pop the overlay. Watching other apps' keys needs Accessibility access.
final class ModifierHoldMonitor {
    var onHold: () -> Void = {}
    var onRelease: () -> Void = {}

    private var monitors: [Any] = []
    private var holdTimer: Timer?
    private var isShowing = false
    /// Set when another key was used during this hold; cleared once all modifiers are up.
    private var spoiled = false

    func start() {
        // Scrolling is deliberately not here: it's how you scroll the overlay while holding.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        // Global monitors see events going to other apps; local ones see our own.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags == AppSettings.trigger.flags {
                if holdTimer == nil, !isShowing, !spoiled { startTimer() }
            } else {
                if flags.isEmpty { spoiled = false }
                endHold()
            }
        } else if holdTimer != nil || isShowing {
            // Any key or click while holding means the user wanted a shortcut, not the overlay.
            spoiled = true
            endHold()
        }
    }

    private func startTimer() {
        holdTimer = Timer.scheduledTimer(withTimeInterval: AppSettings.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdTimer = nil
                self.isShowing = true
                self.onHold()
            }
        }
    }

    private func endHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        if isShowing {
            isShowing = false
            onRelease()
        }
    }
}
