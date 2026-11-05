import AppKit

/// Reads Ghostty's key bindings from its config, for adding to what its menus show.
///
/// `ghostty +list-keybinds` prints every binding in effect and `--default` prints the
/// built-in ones, so anything in the first list but not the second is the user's own.
nonisolated enum GhosttyBindings {
    struct Binding: Hashable {
        /// Ghostty's trigger, e.g. "super+shift+d".
        let trigger: String
        /// Ghostty's action, e.g. "new_split:down".
        let action: String
    }

    /// Ghostty's config files, so it's only re-read when one of them changes.
    private static var configFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".config/ghostty/config", ".config/ghostty/config.ghostty",
                "Library/Application Support/com.mitchellh.ghostty/config",
                "Library/Application Support/com.mitchellh.ghostty/config.ghostty"].map { home.appending(path: $0) }
    }
    private static let cache = ConfigCache<ConfigBindings>()

    /// Returns nil when Ghostty isn't installed or its command line tool fails.
    @Sendable static func load() -> ConfigBindings? {
        guard let ghostty = executable() else { return nil }
        return cache.value(for: configFiles + [URL(fileURLWithPath: ghostty)]) {
            guard let defaults = ProcessRunner.run(ghostty, ["+list-keybinds", "--default"]),
                  let user = ProcessRunner.run(ghostty, ["+list-keybinds"]),
                  !parse(user).isEmpty
            else { return nil }
            return resolve(defaults: defaults, user: user)
        }
    }

    /// The comparison itself, separate from running Ghostty so it can be tested with saved output.
    static func resolve(defaults defaultsText: String, user userText: String) -> ConfigBindings {
        let defaults = parse(defaultsText)
        let defaultSet = Set(defaults)
        let defaultActionByTrigger = Dictionary(defaults.map { ($0.trigger, $0.action) }, uniquingKeysWith: { first, _ in first })
        // Dedicated Copy and Paste keys exist on few keyboards; leave them out.
        let user = parse(userText).filter { $0.trigger != "copy" && $0.trigger != "paste" }
        let userSet = Set(user)

        var items: [ConfigBindings.Item] = []
        var seenKeys: Set<[String]> = []      // super+1 and super+digit_1 both look like ⌘1
        var shownAsAlsoWorks: Set<[String]> = []

        // The user's own bindings first, so a default they've paired up with is greyed beside it.
        for binding in user where !defaultSet.contains(binding) {
            let keys = display(binding.trigger)
            guard seenKeys.insert(keys).inserted else { continue }
            // A default key for the same action that still works.
            let stillWorks = defaults.first { $0.action == binding.action && userSet.contains($0) }
                .map { display($0.trigger) }
            if let stillWorks { shownAsAlsoWorks.insert(stillWorks) }
            // The key used to do something else by default.
            let replaced = defaultActionByTrigger[binding.trigger].flatMap { $0 == binding.action ? nil : $0 }
            items.append(.init(title: describe(binding.action), keys: keys, isCustom: true,
                               alsoWorks: stillWorks, note: replaced.map { "Replaces: \(describe($0))" }))
        }
        for binding in user where defaultSet.contains(binding) {
            let keys = display(binding.trigger)
            guard !shownAsAlsoWorks.contains(keys), seenKeys.insert(keys).inserted else { continue }
            items.append(.init(title: describe(binding.action), keys: keys, isCustom: false))
        }
        return ConfigBindings(source: "Ghostty config", items: items)
    }

    // MARK: - Parsing

    /// Parses lines like `keybind = super+shift+d=new_split:down`.
    static func parse(_ text: String) -> [Binding] {
        text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("keybind = ") else { return nil }
            let body = line.dropFirst("keybind = ".count)
            // The trigger can itself contain "=" (super+= is ⌘=), so the separator is the
            // first "=" that doesn't directly follow a "+".
            var previous: Character = " "
            for index in body.indices {
                if body[index] == "=" && previous != "+" {
                    let trigger = String(body[..<index])
                    let action = String(body[body.index(after: index)...])
                    return Binding(trigger: trigger, action: action)
                }
                previous = body[index]
            }
            return nil
        }
    }

    // MARK: - Display

    private static let modifiers: [(names: Set<String>, symbol: String)] = [
        (["ctrl", "control"], "⌃"), (["alt", "opt", "option"], "⌥"),
        (["shift"], "⇧"), (["super", "cmd", "command"], "⌘"),
    ]

    private static let keyNames: [String: String] = [
        "arrow_up": "↑", "arrow_down": "↓", "arrow_left": "←", "arrow_right": "→",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "enter": "↩", "return": "↩", "escape": "esc", "tab": "⇥", "space": "space",
        "backspace": "⌫", "delete": "⌦", "page_up": "pgup", "page_down": "pgdn",
        "home": "home", "end": "end", "equal": "=", "minus": "-", "plus": "+",
        "comma": ",", "period": ".", "slash": "/", "backslash": "\\", "semicolon": ";",
        "quote": "'", "grave_accent": "`", "bracket_left": "[", "bracket_right": "]",
    ]

    /// Turns a trigger into keycaps in macOS menu order: "super+shift+d" → ["⇧", "⌘", "D"].
    /// Sequences like "ctrl+a>n" become each step's keycaps in turn.
    static func display(_ trigger: String) -> [String] {
        // Prefixes like "global:" change where a binding works, not which keys it uses.
        let keys = trigger.split(separator: ":").last.map(String.init) ?? trigger
        return keys.split(separator: ">").flatMap { step -> [String] in
            var parts = step.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            // "super++" splits into ["super", "", ""]: the key itself is "+".
            if parts.count >= 2, parts.suffix(2) == ["", ""] { parts.removeLast(2); parts.append("+") }
            guard let key = parts.popLast() else { return [] }
            let used = Set(parts.map { $0.lowercased() })
            let caps = modifiers.filter { !$0.names.isDisjoint(with: used) }.map(\.symbol)
            var label = keyNames[key] ?? key
            if label.hasPrefix("digit_") { label = String(label.dropFirst("digit_".count)) }
            if label.count == 1 { label = label.uppercased() }
            return caps + [label]
        }
    }

    /// Ghostty's defaults send these control codes to make shell editing work like macOS.
    private static let textActions: [String: String] = [
        #"text:\x01"#: "Start of line", #"text:\x05"#: "End of line",
        #"text:\x15"#: "Delete to start of line", "esc:b": "Back a word", "esc:f": "Forward a word",
        #"text:\n"#: "New line without running",
    ]

    /// A readable name for an action: "goto_split:left" → "Goto split (left)".
    static func describe(_ action: String) -> String {
        if let known = textActions[action] { return known }
        // text: and esc: send characters to the shell; show them as typed.
        if action.hasPrefix("text:") { return "Send “\(action.dropFirst(5))”" }
        if action.hasPrefix("esc:") { return "Send Esc then “\(action.dropFirst(4))”" }
        let pieces = action.split(separator: ":", maxSplits: 1).map(String.init)
        var name = pieces[0].replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "goto ", with: "go to ")
        name = name.prefix(1).uppercased() + name.dropFirst()
        guard pieces.count > 1 else { return name }
        let argument = pieces[1].replacingOccurrences(of: ",", with: ", ")
        return "\(name) (\(argument))"
    }

    // MARK: - Running Ghostty

    /// Ghostty's command line tool lives inside the app bundle.
    private static func executable() -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
        else { return nil }
        let path = app.appending(path: "Contents/MacOS/ghostty").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
