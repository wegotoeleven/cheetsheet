import Foundation

/// One cheatsheet, read from (and, by the sheet editor, saved to) a JSON file.
///
/// `Decodable` lets `JSONDecoder` build this struct straight from JSON whose keys
/// match the property names, similar to a Python dataclass loaded from a dict.
nonisolated struct Cheatsheet: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    /// SF Symbol name shown in the sidebar.
    let symbol: String
    /// Prefix key (tmux-style). Entries use the token "{prefix}" in their keys.
    let prefix: String?
    /// When the overlay shows this sheet. Nil means only in the main window.
    let show: Show?
    /// For terminal sheets: how deeply nested the program usually is (tmux 1, vim inside it 2).
    /// The overlay shows the most deeply nested layer first.
    let layer: Int?
    let sections: [Section]

    /// In JSON, one of:
    ///   "show": "everywhere"
    ///   "show": { "apps": ["com.apple.Music"] }        (bundle IDs; "@terminals" = any terminal)
    ///   "show": { "terminalTitle": "\\btmux\\b" }       (regex matched against a terminal's window title)
    enum Show: Hashable, Codable {
        case everywhere
        case apps([String])
        case terminalTitle(String)

        private enum Keys: String, CodingKey { case apps, terminalTitle }

        init(from decoder: Decoder) throws {
            if let word = try? decoder.singleValueContainer().decode(String.self) {
                guard word == "everywhere" else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                        debugDescription: "\"show\" should be \"everywhere\", {\"apps\": [...]} or {\"terminalTitle\": \"...\"}"))
                }
                self = .everywhere
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            if let apps = try c.decodeIfPresent([String].self, forKey: .apps) {
                self = .apps(apps)
            } else {
                self = .terminalTitle(try c.decode(String.self, forKey: .terminalTitle))
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .everywhere:
                var c = encoder.singleValueContainer()
                try c.encode("everywhere")
            case .apps(let apps):
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode(apps, forKey: .apps)
            case .terminalTitle(let pattern):
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode(pattern, forKey: .terminalTitle)
            }
        }
    }

    struct Section: Identifiable, Codable, Hashable {
        var id: String { title }
        let title: String
        let entries: [Entry]
    }

    struct Entry: Identifiable, Codable, Hashable {
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

    /// True when this is a terminal sheet (tmux, vim) whose pattern matches the window title.
    func matchesTerminal(bundleID: String?, windowTitle: String?) -> Bool {
        guard case .terminalTitle(let pattern) = show,
              let bundleID, Self.terminalBundleIDs.contains(bundleID),
              let windowTitle else { return false }
        return windowTitle.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// True when this sheet is attached to the given app.
    func attaches(toBundleID bundleID: String?) -> Bool {
        guard case .apps(let apps) = show, let bundleID else { return false }
        return apps.contains { $0 == bundleID || ($0 == "@terminals" && Self.terminalBundleIDs.contains(bundleID)) }
    }

    var showsEverywhere: Bool { show == .everywhere }

    /// The sheet's sections in the same shape as menu shortcuts, with the prefix filled in.
    /// With `live`, changed defaults are struck through and the user's own bindings added.
    func shortcutGroups(live: LiveBindings? = nil) -> [MenuGroup] {
        let prefixCap = live?.prefix ?? prefix ?? "prefix"
        func caps(_ keys: [String]) -> [String] { keys.map { $0 == "{prefix}" ? prefixCap : $0 } }

        var groups = sections.enumerated().map { index, section in
            MenuGroup(id: index, title: section.title, items: section.entries.map { entry in
                let override = live?.overrides[entry.action]
                let defaultKeys = caps(entry.keys)
                // Unchanged, or only the prefix changed (e.g. send-prefix on ⌃a ⌃a): nothing to strike out.
                guard let override, override.keys != defaultKeys else {
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
