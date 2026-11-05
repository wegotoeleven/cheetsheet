import Foundation

/// What's different about the user's real setup compared with a sheet's defaults.
nonisolated struct LiveBindings: Sendable {
    /// The user's prefix as a keycap, e.g. "⌃a". Nil when it's the default.
    var prefix: String?
    /// Entries whose default binding no longer works, keyed by the entry's action.
    var overrides: [String: Override]
    /// The user's own bindings that aren't covered by the sheet.
    var extras: [MenuShortcut]
    /// Where these came from, e.g. "running tmux server".
    var source: String

    struct Override: Sendable {
        /// The user's keys for this action, or nil when nothing does it any more.
        let keys: [String]?
        /// True when the default key still works alongside the user's own.
        let defaultStillWorks: Bool
        /// Why the default changed, e.g. "Unbound".
        let note: String?
    }
}

/// Reads tmux's key bindings and compares them with tmux's own defaults.
///
/// Both lists come from the installed tmux, so the comparison is exact for that
/// version: a binding counts as changed when its command differs from the default.
nonisolated enum TmuxBindings {
    struct Binding: Hashable {
        let table: String
        /// tmux's key name, e.g. "C-a", "%", "Up".
        let key: String
        let command: String
    }

    /// Reads bindings from the running tmux server, or from the config file when
    /// no server is running. Returns nil when tmux isn't installed.
    static func load(for sheet: Cheatsheet) -> LiveBindings? {
        guard let tmux = executable() else { return nil }
        // `-f /dev/null` skips every config file, so this is tmux's pure defaults.
        // `-L` uses a private socket, so the user's own server is never touched.
        guard let defaults = run(tmux, ["-f", "/dev/null", "-L", "cheetsheet-defaults", "start-server", ";", "list-keys"])
        else { return nil }

        // Several tmux commands in one call, separated by ";" as on tmux's command line.
        let query = ["list-keys", ";", "show-options", "-g", "prefix", ";",
                     "list-keys", "-N", "-T", "prefix", "-P", "@prefix ", ";",
                     "list-keys", "-N", "-T", "root", "-P", "@root "]
        // An empty list would make every default look unbound, so treat it as a failure.
        if let live = run(tmux, query), !parse(live).isEmpty {
            return resolve(sheet: sheet, defaults: defaults, user: live, source: "running tmux server")
        }
        // No server running: start a throwaway one that loads the user's config, then exits.
        if let config = run(tmux, ["-L", "cheetsheet-config", "start-server", ";"] + query), !parse(config).isEmpty {
            return resolve(sheet: sheet, defaults: defaults, user: config, source: "tmux config")
        }
        return nil
    }

    /// The comparison itself, separate from running tmux so it can be tested with saved output.
    static func resolve(sheet: Cheatsheet, defaults defaultsText: String, user userText: String,
                        source: String) -> LiveBindings {
        let defaults = index(parse(defaultsText))
        let userBindings = parse(userText)
        let user = index(userBindings)
        let notes = parseNotes(userText)

        let userPrefixKey = userText.split(separator: "\n")
            .first { $0.hasPrefix("prefix ") }
            .map { String($0.dropFirst("prefix ".count)).trimmingCharacters(in: .whitespaces) }
        let prefixCap = userPrefixKey.map(display) ?? sheet.prefix ?? "prefix"

        /// Keycaps for a binding, with the prefix in front for the prefix table.
        func caps(_ binding: Binding) -> [String] {
            binding.table == "prefix" ? [prefixCap, display(binding.key)] : [display(binding.key)]
        }

        var overrides: [String: LiveBindings.Override] = [:]
        var explained: Set<Binding> = []  // user bindings already shown as a moved default

        for entry in sheet.sections.flatMap(\.entries) {
            guard let key = tmuxKey(for: entry.keys),
                  let defaultCommand = defaults[Pair(table: "prefix", key: key)]
            else { continue }
            let current = user[Pair(table: "prefix", key: key)]
            let stillWorks = current == defaultCommand

            // A key the user added for the same command: prefix table first, then keys without the prefix.
            // Only the user's own additions count, not other keys tmux binds to it by default.
            let added = userBindings
                .filter { $0.command == defaultCommand && ($0.table == "prefix" || $0.table == "root") }
                .filter { defaults[Pair(table: $0.table, key: $0.key)] != $0.command }
                .sorted { ($0.table == "prefix" ? 0 : 1) < ($1.table == "prefix" ? 0 : 1) }
                .first
            if stillWorks && added == nil { continue }  // untouched
            if let added { explained.insert(added) }

            let note: String? = switch (stillWorks, added, current) {
            case (true, _, _), (_, .some, _): nil
            case (false, nil, nil): "Unbound"
            case (false, nil, .some(let other)): "Key now runs \(other.prefix(40))"
            }
            overrides[entry.action] = .init(keys: added.map(caps), defaultStillWorks: stillWorks, note: note)
        }

        // Everything else the user added or changed, in the prefix table or without a prefix.
        let extras = userBindings
            .filter { ($0.table == "prefix" || $0.table == "root") && !$0.key.contains("Mouse") }
            .filter { defaults[Pair(table: $0.table, key: $0.key)] != $0.command }
            .filter { !explained.contains($0) && $0.command != "send-prefix" }
            .map { binding in
                MenuShortcut(title: notes[Pair(table: binding.table, key: binding.key)] ?? binding.command,
                             keys: caps(binding))
            }

        let defaultPrefix = sheet.prefix
        return LiveBindings(prefix: prefixCap == defaultPrefix ? nil : prefixCap,
                            overrides: overrides, extras: extras, source: source)
    }

    // MARK: - Parsing

    private struct Pair: Hashable {
        let table: String
        let key: String
    }

    private static func index(_ bindings: [Binding]) -> [Pair: String] {
        // `uniquingKeysWith` decides what to keep if a key appears twice; it shouldn't, so keep the last.
        Dictionary(bindings.map { (Pair(table: $0.table, key: $0.key), $0.command) }, uniquingKeysWith: { $1 })
    }

    /// Parses `list-keys` lines like `bind-key -r -T prefix Up select-pane -U`.
    static func parse(_ text: String) -> [Binding] {
        text.split(separator: "\n").compactMap { line in
            var rest = Substring(line)
            guard nextToken(&rest) == "bind-key" else { return nil }
            var table = "prefix"
            var token = nextToken(&rest)
            while let flag = token, flag.hasPrefix("-"), flag.count == 2 {
                if flag == "-T" { table = nextToken(&rest) ?? table }
                token = nextToken(&rest)
            }
            guard let key = token else { return nil }
            let command = rest.trimmingCharacters(in: .whitespaces)
            return Binding(table: table, key: unescape(key), command: command)
        }
    }

    /// Parses the `@prefix r  Reload config` lines printed by `list-keys -N -P`.
    private static func parseNotes(_ text: String) -> [Pair: String] {
        var notes: [Pair: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("@") {
            var rest = line.dropFirst()
            guard let table = nextToken(&rest), let key = nextToken(&rest) else { continue }
            notes[Pair(table: table, key: unescape(key))] = rest.trimmingCharacters(in: .whitespaces)
        }
        return notes
    }

    /// Removes and returns the next space-separated word.
    private static func nextToken(_ text: inout Substring) -> String? {
        text = text.drop { $0 == " " || $0 == "\t" }
        guard !text.isEmpty else { return nil }
        let word = text.prefix { $0 != " " && $0 != "\t" }
        text = text.dropFirst(word.count)
        return String(word)
    }

    /// tmux escapes some keys in its output, e.g. `\%` or `\;`.
    private static func unescape(_ key: String) -> String {
        key.count > 1 && key.hasPrefix("\\") ? String(key.dropFirst()) : key
    }

    // MARK: - Key names

    /// The tmux key name for a sheet entry like ["{prefix}", "%"], or nil when the
    /// entry stands for several keys (e.g. "←↓↑→") and can't be checked one-to-one.
    private static func tmuxKey(for keys: [String]) -> String? {
        guard keys.count == 2, keys[0] == "{prefix}" else { return nil }
        switch keys[1] {
        case "space": return "Space"
        case "pgup": return "PPage"
        case "pgdn": return "NPage"
        case "{prefix}": return "C-b"  // send-prefix is bound to the default prefix key
        case let key where key.count == 1: return key
        default: return nil
        }
    }

    private static let names: [String: String] = [
        "Up": "↑", "Down": "↓", "Left": "←", "Right": "→",
        "Space": "space", "Enter": "↩", "Escape": "esc", "Tab": "⇥", "BTab": "⇧⇥",
        "BSpace": "⌫", "DC": "⌦", "IC": "ins", "Home": "home", "End": "end",
        "PPage": "pgup", "PageUp": "pgup", "NPage": "pgdn", "PageDown": "pgdn",
    ]

    /// Turns a tmux key name into a keycap label: "C-a" → "⌃a", "M-Up" → "⌥↑".
    static func display(_ key: String) -> String {
        var rest = Substring(key)
        var control = false, option = false, shift = false
        while rest.count > 2, let dash = rest.dropFirst().first, dash == "-" {
            switch rest.first {
            case "C": control = true
            case "M": option = true
            case "S": shift = true
            default: break
            }
            rest = rest.dropFirst(2)
        }
        if rest.count == 2, rest.first == "^" { control = true; rest = rest.dropFirst() }
        let modifiers = (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "")
        return modifiers + (names[String(rest)] ?? String(rest))
    }

    // MARK: - Running tmux

    private static func executable() -> String? { ProcessRunner.find("tmux") }

    /// Runs tmux and returns its output, or nil if it failed (e.g. "no server running").
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        ProcessRunner.run(path, arguments)
    }
}
