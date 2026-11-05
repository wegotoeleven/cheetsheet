import Foundation
import Observation

/// Loads and holds every available cheatsheet.
///
/// `@Observable` makes SwiftUI redraw any view that reads `sheets` when it changes.
@Observable
final class SheetStore {
    private(set) var sheets: [Cheatsheet] = []
    private(set) var loadErrors: [String] = []
    /// The user's real bindings for sheets that can read them (tmux), keyed by sheet ID.
    private(set) var live: [String: LiveBindings] = [:]
    // @ObservationIgnored: bookkeeping that shouldn't redraw any views.
    @ObservationIgnored private var lastLiveRefresh = Date.distantPast
    @ObservationIgnored private var liveRefresh: Task<Void, Never>?

    init() {
        loadBundledSheets()
    }

    /// Reads every .json file shipped inside the app bundle.
    func loadBundledSheets() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        var loaded: [Cheatsheet] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                loaded.append(try JSONDecoder().decode(Cheatsheet.self, from: data))
            } catch {
                loadErrors.append("\(url.lastPathComponent): \(error)")
                print("Failed to load \(url.lastPathComponent): \(error)")
            }
        }
        sheets = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Re-reads tmux's bindings, at most every few seconds. Callers that arrive
    /// while a refresh is running wait for that one instead of starting another.
    func refreshLiveBindings() async {
        if let liveRefresh { return await liveRefresh.value }
        guard Date().timeIntervalSince(lastLiveRefresh) > 5, let tmux = sheet(id: "tmux") else { return }
        let task = Task {
            // Task.detached runs tmux off the main thread so the UI never waits on it.
            let bindings = await Task.detached { TmuxBindings.load(for: tmux) }.value
            live["tmux"] = bindings
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
