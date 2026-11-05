import Foundation

/// One cheatsheet, decoded from a JSON file.
///
/// `Decodable` lets `JSONDecoder` build this struct straight from JSON whose keys
/// match the property names, similar to a Python dataclass loaded from a dict.
nonisolated struct Cheatsheet: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    /// SF Symbol name shown in the sidebar.
    let symbol: String
    /// Prefix key (tmux-style). Entries use the token "{prefix}" in their keys.
    let prefix: String?
    /// When this sheet applies automatically in the overlay. Nil means never.
    let match: Match?
    /// How deeply nested this program usually is: tmux is 1, vim inside it is 2.
    /// The overlay shows the most deeply nested layer first.
    let layer: Int?
    let sections: [Section]

    struct Match: Decodable, Hashable {
        /// Bundle IDs of apps this sheet applies to. "@terminals" means any known terminal.
        let apps: [String]?
        /// Regular expression matched (case-insensitively) against the front window's title.
        let title: String?
    }

    struct Section: Identifiable, Decodable, Hashable {
        var id: String { title }
        let title: String
        let entries: [Entry]
    }

    struct Entry: Identifiable, Decodable, Hashable {
        var id: String { action }
        /// Stable identifier for what the binding does (e.g. tmux's `split-window -h`).
        /// Later used to match against live bindings, so it must be unique per sheet.
        let action: String
        /// Keys pressed in order; each string is drawn as one keycap.
        let keys: [String]
        let description: String
        let note: String?

        func matches(_ query: String) -> Bool {
            description.localizedCaseInsensitiveContains(query)
                || keys.joined(separator: " ").localizedCaseInsensitiveContains(query)
                || (note?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

// An extension adds methods to an existing type, like adding methods to a class after the fact.
nonisolated extension Cheatsheet {
    static let terminalBundleIDs: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
    ]

    /// True when this sheet should appear for the given front app and window title.
    func applies(toBundleID bundleID: String?, windowTitle: String?) -> Bool {
        guard let match else { return false }
        if let apps = match.apps {
            let ids = Set(apps.flatMap { $0 == "@terminals" ? Array(Self.terminalBundleIDs) : [$0] })
            guard let bundleID, ids.contains(bundleID) else { return false }
        }
        if let pattern = match.title {
            guard let windowTitle,
                  windowTitle.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            else { return false }
        }
        return true
    }

    /// The sheet's sections in the same shape as menu shortcuts, with the prefix filled in.
    /// With `live`, changed defaults are struck through and the user's own bindings added.
    func shortcutGroups(live: LiveBindings? = nil) -> [MenuGroup] {
        let prefixCap = live?.prefix ?? prefix ?? "prefix"
        func caps(_ keys: [String]) -> [String] { keys.map { $0 == "{prefix}" ? prefixCap : $0 } }

        var groups = sections.enumerated().map { index, section in
            MenuGroup(id: index, title: section.title, items: section.entries.map { entry in
                let defaultKeys = caps(entry.keys)
                // A new prefix alone isn't a change worth striking out (e.g. send-prefix on ⌃a ⌃a).
                guard let override = live?.overrides[entry.action], override.keys != defaultKeys else {
                    return MenuShortcut(title: entry.description, keys: defaultKeys, note: entry.note)
                }
                if override.defaultStillWorks {
                    // Their key first; the default still works, so it's greyed rather than struck out.
                    return MenuShortcut(title: entry.description, keys: override.keys ?? [],
                                        note: entry.note, alsoWorks: defaultKeys)
                }
                return MenuShortcut(title: entry.description, keys: override.keys ?? [],
                                    note: override.note ?? entry.note, replaced: defaultKeys)
            })
        }
        if let extras = live?.extras, !extras.isEmpty {
            groups.append(MenuGroup(id: sections.count, title: "Your bindings", items: extras))
        }
        return groups
    }
}
