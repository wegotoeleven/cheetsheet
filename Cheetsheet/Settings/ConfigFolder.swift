import Foundation

/// Where Cheetsheet keeps everything you might want in your dotfiles:
/// `~/.config/cheetsheet/config.json` for settings and `sheets/` for your own cheatsheets.
nonisolated enum ConfigFolder {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/cheetsheet")
    static let configFile = url.appending(path: "config.json")
    static let sheetsFolder = url.appending(path: "sheets")

    /// Creates the folders if they're missing. Works when ~/.config/cheetsheet is a symlink
    /// into a dotfiles repo, because creating an existing folder (or its target) is a no-op.
    static func ensureExists() {
        try? FileManager.default.createDirectory(at: sheetsFolder, withIntermediateDirectories: true)
    }

    /// Writes a file without breaking dotfile symlinks: if the path is a symlink (e.g. made by
    /// GNU Stow), the real file it points to is replaced rather than the link itself.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
    }

    /// "~/.config/cheetsheet" rather than the full path.
    static func tildePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// Calls `onChange` when anything in a folder changes, e.g. a sheet saved in a text editor.
///
/// Uses a kernel file-system event source (kqueue) on the folder. Editors usually save by
/// writing a new file and renaming it over the old one, which shows up as a folder change.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?

    init(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        // O_EVTONLY opens the folder only to watch it, so it never blocks unmounting.
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
