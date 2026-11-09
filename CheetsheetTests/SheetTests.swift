import Foundation
import Testing
@testable import Cheetsheet

/// The built-in sheets, the sheet file format, and the settings file.
struct SheetTests {
    /// Every sheet that ships in the app bundle.
    static func builtInSheets() throws -> [Cheatsheet] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return try urls.map { try JSONDecoder().decode(Cheatsheet.self, from: Data(contentsOf: $0)) }
    }

    static func sheet(_ id: String) throws -> Cheatsheet {
        try #require(try builtInSheets().first { $0.id == id })
    }

    @Test func builtInSheetsLoad() throws {
        let ids = Set(try Self.builtInSheets().map(\.id))
        #expect(ids.isSuperset(of: ["tmux", "vim", "herdr"]))
    }

    @Test func builtInSheetsHaveUniqueActionsAndSectionTitles() throws {
        for sheet in try Self.builtInSheets() {
            let actions = sheet.sections.flatMap(\.entries).map(\.action)
            #expect(Set(actions).count == actions.count, "duplicate action in \(sheet.id)")
            let titles = sheet.sections.map(\.title)
            #expect(Set(titles).count == titles.count, "duplicate section in \(sheet.id)")
        }
    }

    @Test(arguments: [
        (#""everywhere""#, Cheatsheet.Show.everywhere),
        (#"{"apps": ["com.apple.finder", "@terminals"]}"#, .apps(["com.apple.finder", "@terminals"])),
        (#"{"terminalTitle": "\\btop\\b"}"#, .terminalTitle(#"\btop\b"#)),
    ])
    func showDecodes(json: String, expected: Cheatsheet.Show) throws {
        let show = try JSONDecoder().decode(Cheatsheet.Show.self, from: Data(json.utf8))
        #expect(show == expected)
    }

    @Test func showTypoGivesReadableError() {
        #expect {
            try JSONDecoder().decode(Cheatsheet.Show.self, from: Data(#""everywere""#.utf8))
        } throws: { error in
            SettingsStore.describe(error).contains(#""show" should be "everywhere""#)
        }
    }

    @Test func showMatching() throws {
        var sheet = try Self.sheet("vim")
        #expect(sheet.matchesTerminal(bundleID: "com.mitchellh.ghostty", windowTitle: "notes.md - VIM"))
        #expect(sheet.matchesTerminal(bundleID: "com.apple.Terminal", windowTitle: "nvim init.lua"))
        #expect(!sheet.matchesTerminal(bundleID: "com.mitchellh.ghostty", windowTitle: "echo $environment"))
        // A title match in an app that isn't a terminal doesn't count.
        #expect(!sheet.matchesTerminal(bundleID: "com.apple.Safari", windowTitle: "vim tips"))

        sheet = Cheatsheet(id: "t", name: "T", symbol: "x", prefix: nil, show: .apps(["@terminals"]), layer: nil, sections: [])
        #expect(sheet.attaches(toBundleID: "com.googlecode.iterm2"))
        #expect(!sheet.attaches(toBundleID: "com.apple.finder"))
    }

    @Test func partialConfigFileUsesDefaults() throws {
        let config = try JSONDecoder().decode(ConfigFile.self, from: Data(#"{"holdDelay": 0.5}"#.utf8))
        #expect(config.holdDelay == 0.5)
        #expect(config.trigger == .command)
        #expect(config.showMenuBarIcon)
        #expect(!config.hideTerminalShortcuts)
    }

    @Test func configMergeKeepsGroupIDsUnique() {
        // Menu ids are menu-bar positions; the Apple menu (0) and empty menus are skipped.
        let menus = (1...5).map { MenuGroup(id: $0, title: "Menu \($0)", items: [MenuShortcut(title: "A\($0)", keys: ["⌘", "\($0)"])]) }
        let config = ConfigBindings(source: "Test config", items: [
            .init(title: "Mine", keys: ["⌘", "M"], isCustom: true),
            .init(title: "Default", keys: ["⌘", "J"], isCustom: false),
            .init(title: "Already in a menu", keys: ["⌘", "1"], isCustom: false),
        ])
        let merged = config.merged(into: menus)
        #expect(Set(merged.map(\.id)).count == merged.count)
        #expect(merged.map(\.title).suffix(2) == ["Your bindings (Test config)", "Not in menus (Test config)"])
        #expect(!merged.last!.items.contains { $0.title == "Already in a menu" })
    }
}
