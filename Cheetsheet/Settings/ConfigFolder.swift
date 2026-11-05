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
/// Uses kernel file-system event sources (kqueue). Editors usually save by writing a new
/// file and renaming it over the old one, which shows up as a change to its folder.
///
/// Dotfile managers like GNU Stow make each file a symlink into a repo, and an edit there
/// doesn't touch this folder, so the folders those links point into are watched too. After
/// every change the watch list is rebuilt, which also recovers when the folder itself is
/// deleted and recreated (as re-stowing does).
final class FolderWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var retry: Timer?

    init(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        watch()
    }

    // The retry timer holds only a weak reference, so it needs no cleanup here.
    deinit { sources.forEach { $0.cancel() } }

    /// The folder, plus every folder that a symlink in it points into.
    private var foldersToWatch: Set<String> {
        let folder = url.resolvingSymlinksInPath()
        var folders: Set<String> = [folder.path]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            let target = item.resolvingSymlinksInPath()
            if target.path != item.path { folders.insert(target.deletingLastPathComponent().path) }
        }
        return folders
    }

    private func watch() {
        sources.forEach { $0.cancel() }
        sources = []
        retry?.invalidate()
        retry = nil
        for path in foldersToWatch {
            // O_EVTONLY opens the folder only to watch it, so it never blocks unmounting.
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onChange()
                    self.watch()  // links may have been added or removed, or the folder replaced
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
        // The folder doesn't exist right now (e.g. mid re-stow): try again shortly.
        if sources.isEmpty {
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onChange()
                    self?.watch()
                }
            }
        }
    }
}
