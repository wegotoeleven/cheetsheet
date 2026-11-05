import AppKit
import ApplicationServices

/// One menu item that has a keyboard shortcut.
nonisolated struct MenuShortcut: Hashable, Sendable {
    let title: String
    /// Modifier symbols in standard order (⌃⌥⇧⌘), then the key.
    let keys: [String]
    var note: String? = nil
    /// Default keys that no longer work because the user changed them; drawn struck through.
    var replaced: [String]? = nil
    /// Default keys that still work but aren't the user's preferred ones; drawn greyed out.
    var alsoWorks: [String]? = nil

    func matches(_ query: String) -> Bool {
        ([title, note ?? ""] + keys).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// One top-level menu (File, Edit, …) and its shortcuts.
nonisolated struct MenuGroup: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let items: [MenuShortcut]
}

/// Reads keyboard shortcuts from another app's menu bar via the Accessibility API.
///
/// `nonisolated` lets this run on a background thread: walking a big app's menus
/// (Xcode, Photoshop) takes long enough that doing it on the main thread would stutter.
nonisolated enum MenuReader {
    static func shortcuts(forPID pid: pid_t) -> [MenuGroup] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let menuBar: AXUIElement = app.value(of: kAXMenuBarAttribute) else { return [] }
        let menus: [AXUIElement] = menuBar.value(of: kAXChildrenAttribute) ?? []

        var groups: [MenuGroup] = []
        // Index 0 is the Apple menu, which belongs to the system, not the app.
        for (index, menu) in menus.enumerated() where index > 0 {
            var items: [MenuShortcut] = []
            collect(menu, into: &items, depth: 0)
            if !items.isEmpty {
                let title: String = menu.value(of: kAXTitleAttribute) ?? ""
                groups.append(MenuGroup(id: index, title: title, items: items))
            }
        }
        return groups
    }

    /// Title of the app's focused window. In terminals this is whatever the shell,
    /// tmux or vim last set it to, which works even when they run over SSH.
    static func focusedWindowTitle(forPID pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let window: AXUIElement = app.value(of: kAXFocusedWindowAttribute) else { return nil }
        return window.value(of: kAXTitleAttribute)
    }

    /// Walks menus and submenus depth-first, appending every item that has a shortcut.
    /// `inout` means the function can modify the caller's array in place.
    private static func collect(_ element: AXUIElement, into items: inout [MenuShortcut], depth: Int) {
        guard depth < 6 else { return }
        let children: [AXUIElement] = element.value(of: kAXChildrenAttribute) ?? []
        for child in children {
            let role: String? = child.value(of: kAXRoleAttribute)
            if role == kAXMenuItemRole,
               let title: String = child.value(of: kAXTitleAttribute), !title.isEmpty,
               let keys = keys(for: child),
               !items.contains(where: { $0.title == title && $0.keys == keys }) {
                items.append(MenuShortcut(title: title, keys: keys))
            }
            collect(child, into: &items, depth: depth + 1)
        }
    }

    private static func keys(for item: AXUIElement) -> [String]? {
        let key: String
        if let char: String = item.value(of: kAXMenuItemCmdCharAttribute), !char.isEmpty,
           let mapped = displayKey(forChar: char) {
            key = mapped
        } else if let glyph: Int = item.value(of: kAXMenuItemCmdGlyphAttribute), let symbol = glyphs[glyph] {
            key = symbol
        } else {
            return nil
        }

        // Bit flags from the Accessibility API. "No command" is set when ⌘ is NOT part of it.
        let mods: Int = item.value(of: kAXMenuItemCmdModifiersAttribute) ?? 0
        var keys: [String] = []
        if mods & (1 << 2) != 0 { keys.append("⌃") }
        if mods & (1 << 1) != 0 { keys.append("⌥") }
        if mods & (1 << 0) != 0 { keys.append("⇧") }
        if mods & (1 << 3) == 0 { keys.append("⌘") }
        keys.append(key)
        return keys
    }

    private static func displayKey(forChar char: String) -> String? {
        guard let scalar = char.unicodeScalars.first else { return nil }
        if let special = specialChars[scalar.value] { return special }
        // Function keys F1–F20 are sent as private-use characters 0xF704 onwards.
        if (0xF704...0xF717).contains(scalar.value) { return "F\(scalar.value - 0xF704 + 1)" }
        guard scalar.value >= 0x21, scalar.value < 0xF700 else { return nil }
        return char.uppercased()
    }

    private static let specialChars: [UInt32: String] = [
        0x20: "Space", 0x0D: "↩", 0x03: "⌤", 0x09: "⇥", 0x1B: "⎋",
        0x08: "⌫", 0x7F: "⌫",
        0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→",
        0xF728: "⌦", 0xF729: "↖", 0xF72B: "↘", 0xF72C: "⇞", 0xF72D: "⇟",
    ]

    /// Menu glyph codes (from Carbon's kMenu…Glyph constants) used for non-character keys.
    private static let glyphs: [Int: String] = [
        0x02: "⇥", 0x04: "⌤", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩", 0x17: "⌫", 0x1B: "⎋",
        0x62: "⇞", 0x6B: "⇟", 0x66: "↖", 0x69: "↘",
        0x64: "←", 0x65: "→", 0x68: "↑", 0x6A: "↓",
        0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5", 0x74: "F6",
        0x75: "F7", 0x76: "F8", 0x77: "F9", 0x78: "F10", 0x79: "F11", 0x7A: "F12",
    ]
}

extension AXUIElement {
    /// Reads one accessibility attribute, returning nil if it's missing or the wrong type.
    /// `<T>` makes this generic: the caller's type annotation picks what to cast to.
    nonisolated func value<T>(of attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

/// Accessibility permission helpers.
enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility access" prompt if not yet granted.
    static func prompt() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
