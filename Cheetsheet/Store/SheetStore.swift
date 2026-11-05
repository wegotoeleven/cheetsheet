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
    /// The user's real bindings for sheets that can read them (tmux), keyed by sheet ID.
    private(set) var live: [String: LiveBindings] = [:]
    /// Bindings from app configs (Ghostty), keyed by bundle ID, added to those apps' menus.
    private(set) var appConfigs: [String: ConfigBindings] = [:]
    // @ObservationIgnored: bookkeeping that shouldn't redraw any views.
    @ObservationIgnored private var lastLiveRefresh = Date.distantPast
    @ObservationIgnored private var liveRefresh: Task<Void, Never>?

    /// IDs of sheets that came from your folder rather than the app.
    private(set) var userSheetIDs: Set<String> = []
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
        func load(_ urls: [URL]) -> [Cheatsheet] {
            urls.compactMap { url in
                do {
                    return try JSONDecoder().decode(Cheatsheet.self, from: Data(contentsOf: url))
                } catch {
                    errors.append("\(url.lastPathComponent): \(SettingsStore.describe(error))")
                    return nil
                }
            }
        }
        let builtIn = load(Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
        let userFiles = (try? FileManager.default.contentsOfDirectory(at: ConfigFolder.sheetsFolder,
                                                                      includingPropertiesForKeys: nil)) ?? []
        let yours = load(userFiles.filter { $0.pathExtension == "json" })

        // Yours win over built-in sheets with the same id.
        var byID = Dictionary(builtIn.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for sheet in yours { byID[sheet.id] = sheet }
        sheets = byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        userSheetIDs = Set(yours.map(\.id))
        loadErrors = errors
        lastLiveRefresh = .distantPast  // a changed tmux sheet should be re-checked
    }

    /// Re-reads tmux's bindings and app configs, at most every few seconds. Callers that
    /// arrive while a refresh is running wait for that one instead of starting another.
    func refreshLiveBindings() async {
        if let liveRefresh { return await liveRefresh.value }
        guard Date().timeIntervalSince(lastLiveRefresh) > 5 else { return }
        let tmux = sheet(id: "tmux")
        let task = Task {
            // Task.detached runs the programs off the main thread so the UI never waits on them;
            // `async let` runs tmux and the app configs at the same time.
            async let tmuxBindings = Task.detached { tmux.flatMap(TmuxBindings.load) }.value
            async let configs = Task.detached {
                AppConfigSources.readers.compactMapValues { $0() }
            }.value
            live["tmux"] = await tmuxBindings
            appConfigs = await configs
            lastLiveRefresh = Date()
        }
        liveRefresh = task
        await task.value
        liveRefresh = nil
    }

    func sheet(id: String) -> Cheatsheet? {
        sheets.first { $0.id == id }
    }
}
