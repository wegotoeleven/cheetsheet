import Foundation

/// Reads the key mappings from your vimrc and compares them with the Vim sheet.
///
/// Vim runs twice in the background: once with your vimrc, once without it (`-u NONE`, but
/// still loading plugins). A mapping only in the first list is one your vimrc made. This is
/// the same "yours minus the defaults" comparison used for tmux and Ghostty.
nonisolated enum VimBindings {
    struct Mapping: Hashable, Decodable {
        /// Vim's mode letters: "n" normal, "x"/"v" visual, "i" insert, " " normal+visual+operator.
        let mode: String
        /// The keys, as Vim shows them: "<Space>ff", "<C-D>", "jk".
        let lhs: String
        /// What the keys do: ":Files<CR>", "y$".
        let rhs: String
    }

    /// Where Vim looks for your config, in Vim's own order. Settings → Terminals uses this too.
    static let vimrcCandidates = [".vimrc", ".vim/vimrc", ".config/vim/vimrc"]

    private struct Lists: Sendable { let defaults: [Mapping], user: [Mapping] }
    /// Running Vim twice takes a moment and runs your vimrc, so only do it when it changed.
    private static let cache = ConfigCache<Lists>()

    /// Returns nil when Vim or a vimrc can't be found, or Vim fails.
    static func load(for sheet: Cheatsheet) -> LiveBindings? {
        guard let vim = ProcessRunner.find("vim"), let vimrc = vimrc() else { return nil }
        let lists = cache.value(for: [vimrc]) {
            // Without a vimrc Vim also skips plugins; turning them back on keeps plugin
            // mappings out of "yours", since both lists then have them.
            guard let defaults = mappings(vim, ["-u", "NONE", "--cmd", "set loadplugins"]),
                  let user = mappings(vim, ["-u", vimrc.path])
            else { return nil }
            return Lists(defaults: defaults, user: user)
        }
        guard let lists else { return nil }
        return resolve(sheet: sheet, defaults: lists.defaults, user: lists.user,
                       source: ConfigFolder.tildePath(vimrc))
    }

    /// The comparison itself, separate from running Vim so it can be tested.
    static func resolve(sheet: Cheatsheet, defaults: [Mapping], user: [Mapping], source: String) -> LiveBindings {
        let defaultSet = Set(defaults)
        let yours = user.filter { !defaultSet.contains($0) && !$0.lhs.hasPrefix("<Plug>") }

        // A normal-mode key on the sheet that your vimrc maps to something else.
        var overrides: [String: LiveBindings.Override] = [:]
        let normal = Dictionary(yours.filter { $0.mode == "n" || $0.mode == " " }.map { (keycaps($0.lhs).map(normalise), $0) },
                                uniquingKeysWith: { first, _ in first })
        for entry in sheet.sections.flatMap(\.entries) where entry.action.hasPrefix("normal:") {
            guard let mapping = normal[entry.keys.map(normalise)] else { continue }
            overrides[entry.action] = .init(keys: nil, defaultStillWorks: false,
                                            note: "Key now runs \(describe(mapping.rhs))")
        }

        // Every mapping of yours, once per keys and action, noting the modes it works in.
        var seen: [String: Int] = [:]
        var extras: [MenuShortcut] = []
        var modes: [[String]] = []
        for mapping in yours {
            let id = mapping.lhs + "\u{0}" + mapping.rhs
            if let index = seen[id] { modes[index].append(mapping.mode); continue }
            seen[id] = extras.count
            modes.append([mapping.mode])
            extras.append(MenuShortcut(title: describe(mapping.rhs), keys: keycaps(mapping.lhs)))
        }
        for index in extras.indices { extras[index].note = modeNote(modes[index]) }
        // Vim lists mappings in no useful order; sort by keys so the list stays put between refreshes.
        extras.sort { $0.keys.joined(separator: " ").localizedStandardCompare($1.keys.joined(separator: " ")) == .orderedAscending }
        return LiveBindings(prefix: nil, overrides: overrides, extras: extras, source: source)
    }

    // MARK: - Display

    private static let names: [String: String] = [
        "cr": "↩", "enter": "↩", "return": "↩", "esc": "esc", "tab": "⇥", "bs": "⌫",
        "del": "⌦", "space": "Space", "up": "↑", "down": "↓", "left": "←", "right": "→",
        "home": "home", "end": "end", "pageup": "pgup", "pagedown": "pgdn",
        "lt": "<", "bar": "|", "bslash": "\\", "nop": "nothing",
    ]

    /// Splits Vim's key notation into keycaps in the Vim sheet's style:
    /// "<Space>ff" → ["Space", "f", "f"], "<C-D>" → ["⌃d"], "<leader>y" stays readable.
    static func keycaps(_ lhs: String) -> [String] {
        var caps: [String] = []
        var rest = Substring(lhs)
        while let first = rest.first {
            if first == "<", let close = rest.firstIndex(of: ">"), rest.distance(from: rest.startIndex, to: close) > 1 {
                caps.append(special(String(rest[rest.index(after: rest.startIndex)..<close])))
                rest = rest[rest.index(after: close)...]
            } else {
                caps.append(String(first))
                rest = rest.dropFirst()
            }
        }
        return caps
    }

    /// "C-D" → "⌃d", "M-x" → "⌥x", "S-Tab" → "⇧⇥", "F5" → "F5".
    private static func special(_ name: String) -> String {
        var parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        // "<C-->" is Ctrl and minus.
        if parts.count >= 2, parts.suffix(2) == ["", ""] { parts.removeLast(2); parts.append("-") }
        let key = parts.removeLast()
        var modifiers = ""
        for part in parts {
            switch part.uppercased() {
            case "C": modifiers += "⌃"
            case "M", "A": modifiers += "⌥"
            case "S": modifiers += "⇧"
            case "D": modifiers += "⌘"
            default: break
            }
        }
        let label = names[key.lowercased()] ?? (key.count == 1 && !modifiers.isEmpty ? key.lowercased() : key)
        return modifiers + label
    }

    /// Ctrl keys are case-insensitive in Vim, so "⌃D" and "⌃d" are the same key.
    private static func normalise(_ cap: String) -> String {
        cap.hasPrefix("⌃") ? cap.lowercased() : cap
    }

    /// A short readable action: ":Files<CR>" → "Files", "<Cmd>w<CR>" → "w".
    static func describe(_ rhs: String) -> String {
        var text = rhs
        for prefix in ["<Cmd>", "<cmd>", ":<C-U>", ":<C-u>", ":"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)); break
        }
        if text.hasSuffix("<CR>") { text = String(text.dropLast(4)) }
        // A plugin's named action: "<Plug>(easymotion-prefix)" → "easymotion prefix".
        if text.hasPrefix("<Plug>(") && text.hasSuffix(")") {
            text = text.dropFirst("<Plug>(".count).dropLast().replacingOccurrences(of: "-", with: " ")
        }
        if text.isEmpty || text == "<Nop>" { return "Does nothing" }
        return text.count > 60 ? text.prefix(59) + "…" : text
    }

    private static func modeNote(_ modes: [String]) -> String? {
        let set = Set(modes)
        if set.contains(" ") || set.contains("n") { return nil }  // works in normal mode: the usual case
        let names = set.sorted().compactMap { mode -> String? in
            switch mode {
            case "v", "x": "Visual"
            case "i": "Insert"
            case "!": "Insert and command line"
            case "c": "Command line"
            case "o": "Operator-pending"
            case "t": "Terminal"
            default: nil
            }
        }
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? nil : unique.joined(separator: ", ") + " mode"
    }

    // MARK: - Running Vim

    private static func vimrc() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return vimrcCandidates.map { home.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Starts Vim with `arguments`, has it write every mapping as JSON to a temporary file,
    /// and quits.
    private static func mappings(_ vim: String, _ arguments: [String]) -> [Mapping]? {
        let output = FileManager.default.temporaryDirectory.appending(path: "cheetsheet-vim-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        // -N: not Vi-compatible. -es: silent batch mode, no screen. -i NONE: don't touch viminfo.
        let arguments = ["-N", "-es", "-i", "NONE"] + arguments + [
            "-c", "call writefile([json_encode(maplist()->map({_, m -> {'mode': m.mode, 'lhs': m.lhs, 'rhs': m.rhs}}))], $CHEETSHEET_OUT)",
            "-c", "qa!",
        ]
        // Vim exits with an error code if the vimrc had any error, even a harmless one,
        // so the file it wrote is what counts.
        guard ProcessRunner.run(vim, arguments, environment: ["CHEETSHEET_OUT": output.path],
                                requireSuccess: false) != nil,
              let data = try? Data(contentsOf: output) else { return nil }
        return try? JSONDecoder().decode([Mapping].self, from: data)
    }
}
