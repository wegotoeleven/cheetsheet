import Foundation

/// A config file (vim, Neovim, tmux, herdr) that needs a line or two so the program
/// puts its name in the terminal's window title, which is how Cheetsheet detects it.
struct TerminalConfig: Identifiable {
    let id: String
    let name: String
    /// Paths relative to the home folder; the first one that exists is used.
    let candidates: [String]
    /// Regular expressions that must all match for the file to count as set up.
    let patterns: [String]
    /// The block to append, given the file's extension (Neovim differs for .lua).
    let lines: (_ fileExtension: String) -> String
    /// How the file's text changes. Nil when it can't be changed safely, so you edit the
    /// file yourself. Usually the lines go at the end of the file.
    var change: (_ text: String, _ lines: String) -> Change? = { text, lines in
        Change(updated: text + lines, summary: "These lines will be added to the end of the file:\n" + lines.trimmed)
    }

    /// The file's new text, and what changed, for the confirmation dialog.
    struct Change {
        let updated: String
        let summary: String
    }

    struct Status {
        let config: TerminalConfig
        /// The path as you'd type it, e.g. ~/.vimrc. Nil when no config file exists.
        let url: URL?
        /// Where that path really points, following symlinks (e.g. into a dotfiles repo).
        let resolved: URL?
        let isConfigured: Bool
        /// What setting it up would change, or nil when it can't be done safely.
        let changeSummary: String?
    }

    func status() -> Status {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let url = candidates.map({ home.appending(path: $0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            return Status(config: self, url: nil, resolved: nil, isConfigured: false, changeSummary: nil)
        }
        let resolved = url.resolvingSymlinksInPath()
        let text = (try? String(contentsOf: resolved, encoding: .utf8)) ?? ""
        let configured = patterns.allSatisfy { text.range(of: $0, options: .regularExpression) != nil }
        return Status(config: self, url: url, resolved: resolved, isConfigured: configured,
                      changeSummary: change(text, lines(resolved.pathExtension))?.summary)
    }

    /// Changes the real file. Never creates a new file: a brand-new ~/.vimrc would switch
    /// off vim's built-in defaults.
    static func apply(_ status: Status) throws {
        guard let target = status.resolved else { return }
        // Read again: the file may have changed since the status was taken.
        let text = try String(contentsOf: target, encoding: .utf8)
        guard let change = status.config.change(text, status.config.lines(target.pathExtension)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The file changed; edit it by hand."])
        }
        try Data(change.updated.utf8).write(to: target)
    }

    /// Adds `suffix` to the end of a quoted setting, inside the quotes, so your own
    /// format is kept. `pattern` finds the setting and names its quoted value `value`;
    /// the last match is used, since the last setting is the one in effect. Nil if none matches.
    static func appendInsideValue(_ text: String, pattern: String, suffix: String)
        -> (updated: String, line: String)? {
        guard let regex = try? Regex(pattern), let match = text.matches(of: regex).last,
              let value = match["value"]?.range else { return nil }
        let closing = text.index(before: value.upperBound)
        let line = text.lineRange(for: match.range)
        let newLine = text[line.lowerBound..<closing] + suffix + text[closing..<line.upperBound]
        return (String(text[..<closing]) + suffix + text[closing...], newLine.trimmed)
    }

    // `#"..."#` is a raw string: backslashes are kept as-is, handy for regular expressions.
    private static let vimSetTitle = #"(?m)^\s*set\s+([^"\n]*\s)?title\b"#
    /// A one-line quoted string, "..." (with escapes) or '...', as the value `value`.
    private static let quotedValue = #"(?<value>"(?:[^"\\\n]|\\.)*"|'[^'\n]*')[ \t]*(#.*)?$"#
    private static let tmuxTitlesOn = #"(?m)^\s*set(-option)?\s+(-\w+\s+)*set-titles\s+on\b"#
    private static let tmuxTitlesString = #"(?m)^[ \t]*set(-option)?[ \t]+(-\w+[ \t]+)*set-titles-string[ \t]+"#

    static let all: [TerminalConfig] = [
        TerminalConfig(
            id: "tmux",
            name: "tmux",
            candidates: [".tmux.conf", ".config/tmux/tmux.conf"],
            patterns: [tmuxTitlesOn, #"(?m)^\s*set(-option)?\s+(-\w+\s+)*set-titles-string\s+.*tmux"#],
            lines: { _ in
                "\n# Added by Cheetsheet: shows tmux in the window title so it can be detected\nset -g set-titles on\nset -g set-titles-string \"#T — tmux\"\n"
            },
            // A set-titles-string you already have keeps its format, with " — tmux" added.
            change: { text, lines in
                guard text.range(of: tmuxTitlesString, options: .regularExpression) != nil else {
                    return Change(updated: text + lines, summary: "These lines will be added to the end of the file:\n" + lines.trimmed)
                }
                var updated = text
                var summary: [String] = []
                if text.range(of: #"(?m)^\s*set(-option)?\s+(-\w+\s+)*set-titles-string\s+.*tmux"#, options: .regularExpression) == nil {
                    // Not a one-line quoted string, so it's left for you to edit.
                    guard let edit = appendInsideValue(text, pattern: tmuxTitlesString + quotedValue, suffix: " — tmux")
                    else { return nil }
                    updated = edit.updated
                    summary.append("“ — tmux” will be added to your set-titles-string:\n" + edit.line)
                }
                if text.range(of: tmuxTitlesOn, options: .regularExpression) == nil {
                    // At the end, so it comes after any "set-titles off".
                    let on = "\n# Added by Cheetsheet: shows tmux in the window title so it can be detected\nset -g set-titles on\n"
                    updated += on
                    summary.append("This line will be added to the end of the file:\n" + on.trimmed)
                }
                return summary.isEmpty ? nil : Change(updated: updated, summary: summary.joined(separator: "\n\n"))
            }
        ),
        TerminalConfig(
            id: "herdr",
            name: "herdr",
            candidates: [HerdrBindings.configPath],
            patterns: [#"(?mi)^\s*window_title\s*=.*herdr"#],
            lines: { _ in
                "# Added by Cheetsheet: shows herdr in the window title so it can be detected\nwindow_title = \"{workspace}: {terminal_title} — herdr\"\n"
            },
            // TOML allows one [ui] table and one window_title. A window_title you already set
            // keeps its format, with " — herdr" added; otherwise the lines go into [ui].
            change: { text, lines in
                if text.range(of: #"(?m)^\s*window_title\s*="#, options: .regularExpression) != nil {
                    guard let edit = appendInsideValue(text, pattern: #"(?m)^[ \t]*window_title[ \t]*=[ \t]*"# + quotedValue,
                                                       suffix: " — herdr") else { return nil }
                    return Change(updated: edit.updated, summary: "“ — herdr” will be added to your window_title:\n" + edit.line)
                }
                // `ui = { ... }` or `ui.x = ...` already define the table without a [ui]
                // header, and adding one would make the file invalid.
                guard text.range(of: #"(?m)^[ \t]*ui[ \t]*[=.]"#, options: .regularExpression) == nil else { return nil }
                if let header = text.range(of: #"(?m)^[ \t]*\[ui\][ \t]*(#.*)?$"#, options: .regularExpression) {
                    var updated = text
                    updated.insert(contentsOf: "\n" + lines.trimmingCharacters(in: .newlines), at: header.upperBound)
                    return Change(updated: updated, summary: "These lines will be added to the [ui] table:\n" + lines.trimmed)
                }
                let block = "\n[ui]\n" + lines
                let separator = text.hasSuffix("\n") || text.isEmpty ? "" : "\n"
                return Change(updated: text + separator + block,
                              summary: "These lines will be added to the end of the file:\n" + block.trimmed)
            }
        ),
        TerminalConfig(
            id: "vim",
            name: "Vim",
            candidates: VimBindings.vimrcCandidates,
            patterns: [vimSetTitle],
            lines: { _ in
                "\n\" Added by Cheetsheet: shows vim in the window title so it can be detected\nset title\n"
            }
        ),
        TerminalConfig(
            id: "nvim",
            name: "Neovim",
            candidates: [".config/nvim/init.lua", ".config/nvim/init.vim"],
            patterns: [#"(?m)(^\s*set\s+([^"\n]*\s)?title\b|vim\.(o|opt)\.title\s*=\s*true)"#],
            lines: { ext in
                ext == "lua"
                    ? "\n-- Added by Cheetsheet: shows Neovim in the window title so it can be detected\nvim.opt.title = true\n"
                    : "\n\" Added by Cheetsheet: shows Neovim in the window title so it can be detected\nset title\n"
            }
        ),
    ]
}

private extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
