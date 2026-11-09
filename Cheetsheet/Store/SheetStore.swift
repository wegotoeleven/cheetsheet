import Foundation
import Observation

/// Loads and holds every cheatsheet: the built-in ones, then yours from
/// ~/.config/cheetsheet/sheets (where a sheet with the same id replaces a built-in one).
///
/// `@Observable` makes SwiftUI redraw any view that reads `sheets` when it changes.
@Observable
final class SheetStore {
    private(set) var sheets: [Cheatsheet] = []
    private(set) var loadErrors: [String] = []
    /// The user's real bindings for sheets that can read them (tmux, vim), keyed by sheet ID.
    private(set) var live: [String: LiveBindings] = [:]
    /// Bindings from app configs (Ghostty), keyed by bundle ID, added to those apps' menus.
    private(set) var appConfigs: [String: ConfigBindings] = [:]
    // @ObservationIgnored: bookkeeping that shouldn't redraw any views.
    @ObservationIgnored private var lastLiveRefresh = Date.distantPast
    /// Goes up each time live bindings are re-read, so the overlay knows to redraw.
    @ObservationIgnored private(set) var liveGeneration = 0
    @ObservationIgnored private var liveRefresh: Task<Void, Never>?
    /// Goes up each time the sheets are reloaded, so a refresh can tell its sheets went stale.
    @ObservationIgnored private var sheetsVersion = 0

    /// The file each of your sheets came from, by sheet ID.
    private(set) var userSheetFiles: [String: URL] = [:]
    /// IDs of the sheets that come with the app, whether or not yours replaces them.
    private(set) var builtInIDs: Set<String> = []
    var userSheetIDs: Set<String> { Set(userSheetFiles.keys) }
    @ObservationIgnored private var watcher: FolderWatcher?

    init() {
        ConfigFolder.ensureExists()
        loadSheets()
        // Pick up sheets added, edited or removed in the folder while Cheetsheet runs.
        watcher = FolderWatcher(ConfigFolder.sheetsFolder) { [weak self] in self?.loadSheets() }
    }

    /// Reads the built-in sheets, then every .json file in your sheets folder.
    func loadSheets() {
        var errors: [String] = []
        func load(_ urls: [URL]) -> [(sheet: Cheatsheet, url: URL)] {
            urls.compactMap { url in
                do {
                    return (try JSONDecoder().decode(Cheatsheet.self, from: Data(contentsOf: url)), url)
                } catch {
                    errors.append("\(url.lastPathComponent): \(SettingsStore.describe(error))")
                    return nil
                }
            }
        }
        let builtIn = load(Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []).map(\.sheet)
        let userFiles = (try? FileManager.default.contentsOfDirectory(at: ConfigFolder.sheetsFolder,
                                                                      includingPropertiesForKeys: nil)) ?? []
        let yours = load(userFiles.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent })

        // Yours win over built-in sheets with the same id.
        var byID = Dictionary(builtIn.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var files: [String: URL] = [:]
        for (sheet, url) in yours {
            if files[sheet.id] != nil {
                errors.append("\(url.lastPathComponent): another file already uses the id \"\(sheet.id)\", so this one is ignored")
                continue
            }
            byID[sheet.id] = sheet
            files[sheet.id] = url
        }
        sheets = byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        userSheetFiles = files
        builtInIDs = Set(builtIn.map(\.id))
        loadErrors = errors
        sheetsVersion += 1
        lastLiveRefresh = .distantPast  // a changed tmux sheet should be re-checked
    }

    /// Re-reads tmux's bindings and app configs, at most every few seconds. Callers that
    /// arrive while a refresh is running wait for that one instead of starting another.
    func refreshLiveBindings() async {
        if let liveRefresh { return await liveRefresh.value }
        guard Date().timeIntervalSince(lastLiveRefresh) > 5 else { return }
        let tmux = sheet(id: "tmux"), vim = sheet(id: "vim"), herdr = sheet(id: "herdr")
        let version = sheetsVersion
        let task = Task {
            // Task.detached runs the programs off the main thread so the UI never waits on them;
            // `async let` runs tmux and the app configs at the same time.
            async let tmuxBindings = Task.detached { tmux.flatMap(TmuxBindings.load) }.value
            async let vimBindings = Task.detached { vim.flatMap(VimBindings.load) }.value
            async let herdrBindings = Task.detached { herdr.flatMap(HerdrBindings.load) }.value
            async let configs = Task.detached {
                AppConfigSources.readers.compactMapValues { $0() }
            }.value
            live["tmux"] = await tmuxBindings
            live["vim"] = await vimBindings
            live["herdr"] = await herdrBindings
            appConfigs = await configs
            // If the sheets were reloaded meanwhile, these results used the old ones, so
            // don't count this refresh: the next caller does a fresh one straight away.
            if sheetsVersion == version { lastLiveRefresh = Date() }
            liveGeneration += 1
        }
        liveRefresh = task
        await task.value
        liveRefresh = nil
    }

    func sheet(id: String) -> Cheatsheet? {
        sheets.first { $0.id == id }
    }

    // MARK: - Saving from the sheet editor

    /// Writes a sheet to your folder: over its own file if it has one, otherwise to a new
    /// `<id>.json`. Saving a built-in sheet this way makes your copy, which replaces it.
    func save(_ sheet: Cheatsheet) throws {
        let encoder = JSONEncoder()
        // Sorted keys, so saving the same sheet twice gives the same file (tidy dotfile diffs).
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sheet)
        try ConfigFolder.write(data, to: userSheetFiles[sheet.id] ?? newFileURL(for: sheet.id))
        loadSheets()
    }

    /// Moves your file for a sheet to the Bin. For a copy of a built-in sheet, the built-in
    /// one comes back.
    func deleteUserSheet(id: String) throws {
        guard let url = userSheetFiles[id] else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        loadSheets()
    }

    /// An id no other sheet uses, made from a name: "My Keys" → "my-keys", then "my-keys-2".
    func unusedID(for name: String) -> String {
        let base = name.slug.isEmpty ? "sheet" : name.slug
        let taken = builtInIDs.union(userSheetIDs)
        var id = base, n = 2
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    /// `<id>.json` in your folder, numbered if a file of that name already holds another sheet.
    private func newFileURL(for id: String) -> URL {
        var url = ConfigFolder.sheetsFolder.appending(path: "\(id).json"), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = ConfigFolder.sheetsFolder.appending(path: "\(id)-\(n).json"); n += 1
        }
        return url
    }
}
