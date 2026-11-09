import Foundation

/// Reads the `[keys]` table of your herdr config and compares it with herdr's defaults.
///
/// The defaults come from `herdr --default-config`, which prints every binding as a
/// commented-out line, so the comparison follows the installed version. herdr has no
/// command that prints the bindings in effect, so your side is read from config.toml.
nonisolated enum HerdrBindings {
    /// herdr's `[keys]` table: bindings by action name, plus `[[keys.command]]` entries.
    struct Keys: Equatable {
        /// e.g. "split_vertical" → ["prefix+v"]. An action set to "" maps to [].
        var actions: [String: [String]] = [:]
        var commands: [Command] = []
    }

    struct Command: Equatable {
        var key: String?
        var command: String?
        var description: String?
    }

    static let configPath = ".config/herdr/config.toml"

    /// `herdr --default-config` only changes when herdr is upgraded, so it's kept per binary.
    private static let cache = ConfigCache<String>(maxAge: .infinity)

    /// Returns nil when herdr or its config can't be found.
    static func load(for sheet: Cheatsheet) -> LiveBindings? {
        guard let herdr = ProcessRunner.find("herdr") else { return nil }
        let config = FileManager.default.homeDirectoryForCurrentUser.appending(path: configPath)
        guard let user = try? String(contentsOf: config.resolvingSymlinksInPath(), encoding: .utf8),
              let defaults = cache.value(for: [URL(fileURLWithPath: herdr)], compute: {
                  ProcessRunner.run(herdr, ["--default-config"])
              })
        else { return nil }
        return resolve(sheet: sheet, defaults: parse(uncommented(defaults)), user: parse(user),
                       source: ConfigFolder.tildePath(config))
    }

    /// The comparison itself, separate from running herdr so it can be tested.
    static func resolve(sheet: Cheatsheet, defaults: Keys, user: Keys, source: String) -> LiveBindings {
        let prefixCap = (user.actions["prefix"]?.first ?? defaults.actions["prefix"]?.first).map(display)
            ?? sheet.prefix ?? "prefix"
        func caps(_ binding: String) -> [String] {
            binding.hasPrefix("prefix+") ? [prefixCap, display(String(binding.dropFirst("prefix+".count)))]
                                         : [display(binding)]
        }

        let mine = user.actions.filter { $0.key != "prefix" && $0.value != defaults.actions[$0.key] }
        /// Which of your actions now uses a key. herdr gives your binding the key and
        /// drops the default that had it.
        let takenBy = Dictionary(mine.flatMap { action, keys in keys.map { ($0, action) } },
                                 uniquingKeysWith: { first, _ in first })
        /// Which of your custom commands uses a key, by the name shown for it.
        let commandOn = Dictionary(user.commands.compactMap { command in
            command.key.map { ($0, commandTitle(command)) }
        }, uniquingKeysWith: { first, _ in first })
        // Sheet entries herdr prints a default for. Some it doesn't (swap_pane_* and copy_mode in
        // 0.9.5), so your keys for those can't be compared and are listed as your bindings instead.
        let onSheet = Set(sheet.sections.flatMap(\.entries).map(\.action))
            .filter { defaults.actions[$0]?.first != nil }

        var overrides: [String: LiveBindings.Override] = [:]
        for action in onSheet {
            guard let defaultKey = defaults.actions[action]?.first else { continue }
            let current = mine[action] ?? defaults.actions[action] ?? []
            let thief = takenBy[defaultKey].flatMap { $0 == action ? nil : title($0) } ?? commandOn[defaultKey]
            let stillWorks = current.contains(defaultKey) && thief == nil
            let added = mine[action]?.first { $0 != defaultKey }
            if stillWorks && added == nil { continue }

            let note: String? = switch (stillWorks, added, thief) {
            case (true, _, _), (_, .some, _): nil
            case (false, nil, .some(let other)): "Key now runs \(other)"
            case (false, nil, nil): "Unbound"
            }
            overrides[action] = .init(keys: added.map(caps), defaultStillWorks: stillWorks, note: note)
        }

        // Actions the sheet doesn't list (such as ones herdr leaves unbound), then custom commands.
        let actions = mine.filter { !onSheet.contains($0.key) }
            .sorted { $0.key < $1.key }
            .flatMap { action, keys in keys.map { MenuShortcut(title: title(action), keys: caps($0)) } }
        let commands = user.commands.compactMap { command in
            command.key.map { MenuShortcut(title: commandTitle(command), keys: caps($0)) }
        }

        return LiveBindings(prefix: prefixCap == sheet.prefix ? nil : prefixCap,
                            overrides: overrides, extras: actions + commands, source: source)
    }

    /// A custom command's name: its description, else the command itself.
    static func commandTitle(_ command: Command) -> String {
        command.description ?? command.command ?? "Command"
    }

    /// "split_vertical" → "Split vertical".
    static func title(_ action: String) -> String {
        let words = action.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: - Parsing

    /// `herdr --default-config` comments every setting out; this puts them back so the
    /// same parser reads both files. Prose comments don't look like `name = value`, so
    /// they're skipped either way.
    static func uncommented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                return trimmed.hasPrefix("#") ? String(trimmed.drop { $0 == "#" || $0 == " " }) : String(line)
            }
            .joined(separator: "\n")
    }

    /// Reads just enough TOML for herdr's `[keys]` table: strings and arrays of strings,
    /// including arrays that span several lines.
    static func parse(_ text: String) -> Keys {
        var keys = Keys()
        var table = ""
        var pending = ""  // a key = [ ... ] spread over several lines

        for rawLine in text.split(separator: "\n") {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if !pending.isEmpty {
                pending += " " + line
                guard line.contains("]") else { continue }
            } else if line.hasPrefix("[") && !line.contains("=") {
                table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
                if table == "keys.command" && line.hasPrefix("[[") { keys.commands.append(Command()) }
                continue
            } else if table == "keys" || table == "keys.command" {
                if line.range(of: #"=\s*\[[^\]]*$"#, options: .regularExpression) != nil { pending = line; continue }
                pending = line
            } else {
                continue
            }

            let assignment = pending
            pending = ""
            guard let equals = assignment.firstIndex(of: "=") else { continue }
            let name = assignment[..<equals].trimmingCharacters(in: .whitespaces)
            let values = strings(in: String(assignment[assignment.index(after: equals)...]))

            if table == "keys" {
                keys.actions[name == "fullscreen" ? "zoom" : name] = values.filter { !$0.isEmpty }
            } else if !keys.commands.isEmpty {
                let value = values.first
                switch name {
                case "key": keys.commands[keys.commands.count - 1].key = value
                case "command": keys.commands[keys.commands.count - 1].command = value
                case "description": keys.commands[keys.commands.count - 1].description = value
                default: break
                }
            }
        }
        return keys
    }

    /// Every quoted string in a TOML value: `"a"` → ["a"], `["a", 'b']` → ["a", "b"].
    private static func strings(in value: String) -> [String] {
        var result: [String] = []
        var current: String?
        var quote: Character = "\""
        var escaped = false
        for character in value {
            if var text = current {
                if escaped { text.append(character); escaped = false; current = text }
                else if character == "\\" && quote == "\"" { escaped = true }
                else if character == quote { result.append(text); current = nil }
                else { text.append(character); current = text }
            } else if character == "\"" || character == "'" {
                quote = character
                current = ""
            }
        }
        return result
    }

    /// Drops a trailing `# comment`, leaving any # inside quotes alone.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    // MARK: - Key names

    private static let names: [String: String] = [
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "enter": "↩", "return": "↩", "tab": "⇥", "esc": "esc", "escape": "esc", "space": "space",
        "backspace": "⌫", "delete": "⌦", "home": "home", "end": "end",
        "pageup": "pgup", "pagedown": "pgdn",
        "minus": "-", "plus": "+", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "ampersand": "&", "backtick": "`", "semicolon": ";", "equal": "=", "equals": "=",
        "1..9": "1–9",
    ]

    /// Turns herdr's key syntax into one keycap: "ctrl+a" → "⌃a", "shift+n" → "N",
    /// "shift+tab" → "⇧⇥". A trailing "+" is the plus key itself.
    static func display(_ key: String) -> String {
        var parts = key.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if key.hasSuffix("+") { parts.removeLast(2); parts.append("plus") }
        guard let last = parts.popLast() else { return key }
        let modifiers = Set(parts)
        var base = names[last] ?? last
        var shift = modifiers.contains("shift")
        // A shifted letter reads as the capital, as on the tmux sheet.
        if shift, base.count == 1, base.first?.isLetter == true { base = base.uppercased(); shift = false }
        let symbols = (modifiers.contains("ctrl") || modifiers.contains("control") ? "⌃" : "")
            + (modifiers.contains("alt") || modifiers.contains("option") ? "⌥" : "")
            + (shift ? "⇧" : "")
            + (modifiers.contains("cmd") || modifiers.contains("super") ? "⌘" : "")
        return symbols + base
    }
}
