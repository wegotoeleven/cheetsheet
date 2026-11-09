import Foundation

/// A config file (vim, Neovim, tmux) that needs a line or two so the program
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
    /// Where the lines go in the file's text, and exactly what is inserted there. Nil when
    /// they can't be added safely, so you edit the file yourself. Usually the end of the file.
    var place: (_ text: String, _ lines: String) -> (at: String.Index, insert: String)? = { ($0.endIndex, $1) }

    struct Status {
        let config: TerminalConfig
        /// The path as you'd type it, e.g. ~/.vimrc. Nil when no config file exists.
        let url: URL?
        /// Where that path really points, following symlinks (e.g. into a dotfiles repo).
        let resolved: URL?
        let isConfigured: Bool
        /// What adding the lines would insert, or nil when they can't be added safely.
        let linesToAdd: String?
    }

    func status() -> Status {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let url = candidates.map({ home.appending(path: $0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            return Status(config: self, url: nil, resolved: nil, isConfigured: false, linesToAdd: nil)
        }
        let resolved = url.resolvingSymlinksInPath()
        let text = (try? String(contentsOf: resolved, encoding: .utf8)) ?? ""
        let configured = patterns.allSatisfy { text.range(of: $0, options: .regularExpression) != nil }
        return Status(config: self, url: url, resolved: resolved, isConfigured: configured,
                      linesToAdd: place(text, lines(resolved.pathExtension))?.insert)
    }

    /// Adds the lines to the real file, usually at the end. Never creates a new file:
    /// a brand-new ~/.vimrc would switch off vim's built-in defaults.
    static func append(_ status: Status) throws {
        guard let target = status.resolved else { return }
        // Read again: the file may have changed since the status was taken.
        let text = try String(contentsOf: target, encoding: .utf8)
        guard let (index, insert) = status.config.place(text, status.config.lines(target.pathExtension)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The file changed; add the lines by hand."])
        }
        if index == text.endIndex {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(insert.utf8))
        } else {
            var updated = text
            updated.insert(contentsOf: insert, at: index)
            try Data(updated.utf8).write(to: target)
        }
    }

    // `#"..."#` is a raw string: backslashes are kept as-is, handy for regular expressions.
    private static let vimSetTitle = #"(?m)^\s*set\s+([^"\n]*\s)?title\b"#

    static let all: [TerminalConfig] = [
        TerminalConfig(
            id: "tmux",
            name: "tmux",
            candidates: [".tmux.conf", ".config/tmux/tmux.conf"],
            patterns: [
                #"(?m)^\s*set(-option)?\s+(-\w+\s+)*set-titles\s+on\b"#,
                #"(?m)^\s*set(-option)?\s+(-\w+\s+)*set-titles-string\s+.*tmux"#,
            ],
            lines: { _ in
                "\n# Added by Cheetsheet: shows tmux in the window title so it can be detected\nset -g set-titles on\nset -g set-titles-string \"#T — tmux\"\n"
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
