import Foundation

/// Key bindings an app keeps in its own config, beyond what its menus show.
///
/// Every app's shortcuts come from its menus. For apps whose config Cheetsheet can read
/// (so far Ghostty), these add the bindings that have no menu item, such as moving between
/// splits. Each app needs its own reader because each stores bindings differently, but they
/// all produce this, and the overlay treats every app the same way.
nonisolated struct ConfigBindings: Sendable {
    /// Shown in group titles, e.g. "Ghostty config".
    let source: String
    let items: [Item]

    struct Item: Sendable {
        let title: String
        let keys: [String]
        /// True when the user added or changed this binding; false for the app's defaults.
        let isCustom: Bool
        /// A default key that still does the same thing, shown greyed after the user's own.
        var alsoWorks: [String]? = nil
        var note: String? = nil
    }

    /// The app's menus followed by config bindings the menus don't already show.
    func merged(into menus: [MenuGroup]) -> [MenuGroup] {
        // A binding whose keys are already on a menu item is already on screen.
        let menuKeys = Set(menus.flatMap(\.items).map(\.keys))
        let extra = items.filter { !menuKeys.contains($0.keys) }

        func group(_ id: Int, _ title: String, _ items: [Item]) -> MenuGroup? {
            guard !items.isEmpty else { return nil }
            return MenuGroup(id: id, title: title, items: items.map {
                MenuShortcut(title: $0.title, keys: $0.keys, note: $0.note, alsoWorks: $0.alsoWorks)
            })
        }
        // Menu group ids are menu-bar positions with gaps, so start after the highest one.
        let nextID = (menus.map(\.id).max() ?? 0) + 1
        return menus + [
            group(nextID, "Your bindings (\(source))", extra.filter(\.isCustom)),
            group(nextID + 1, "Not in menus (\(source))", extra.filter { !$0.isCustom }),
        ].compactMap { $0 }
    }
}

/// The apps whose config Cheetsheet can read, by bundle ID.
nonisolated enum AppConfigSources {
    static let readers: [String: @Sendable () -> ConfigBindings?] = [
        "com.mitchellh.ghostty": GhosttyBindings.load,
    ]
}
