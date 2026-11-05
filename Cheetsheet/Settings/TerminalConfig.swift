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

    struct Status {
        let config: TerminalConfig
        /// The path as you'd type it, e.g. ~/.vimrc. Nil when no config file exists.
        let url: URL?
        /// Where that path really points, following symlinks (e.g. into a dotfiles repo).
        let resolved: URL?
        let isConfigured: Bool

        var linesToAdd: String { config.lines(resolved?.pathExtension ?? "") }
    }

    func status() -> Status {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let url = candidates.map({ home.appending(path: $0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            return Status(config: self, url: nil, resolved: nil, isConfigured: false)
        }
        let resolved = url.resolvingSymlinksInPath()
        let text = (try? String(contentsOf: resolved, encoding: .utf8)) ?? ""
        let configured = patterns.allSatisfy { text.range(of: $0, options: .regularExpression) != nil }
        return Status(config: self, url: url, resolved: resolved, isConfigured: configured)
    }

    /// Appends the lines to the end of the real file. Never creates a new file:
    /// a brand-new ~/.vimrc would switch off vim's built-in defaults.
    static func append(_ status: Status) throws {
        guard let target = status.resolved else { return }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(status.linesToAdd.utf8))
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
