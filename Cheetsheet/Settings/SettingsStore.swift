import Foundation
import Observation

/// The settings saved in ~/.config/cheetsheet/config.json.
///
/// Any setting missing from the file gets its default, so a hand-written file only
/// needs the lines you want to change.
nonisolated struct ConfigFile: Codable, Equatable {
    var trigger: TriggerKey = .command
    /// Seconds to hold the trigger key before the overlay appears.
    var holdDelay: Double = 0.8
    var showMenuBarIcon = true
    /// Hide the terminal's own shortcuts when tmux, herdr or vim is detected inside it.
    var hideTerminalShortcuts = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ConfigFile()
        trigger = try c.decodeIfPresent(TriggerKey.self, forKey: .trigger) ?? defaults.trigger
        holdDelay = try c.decodeIfPresent(Double.self, forKey: .holdDelay) ?? defaults.holdDelay
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? defaults.showMenuBarIcon
        hideTerminalShortcuts = try c.decodeIfPresent(Bool.self, forKey: .hideTerminalShortcuts) ?? defaults.hideTerminalShortcuts
    }
}

/// Loads, saves and watches config.json. Edits from Settings are written straight away;
/// edits made to the file elsewhere (a text editor, a dotfiles pull) are picked up live.
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    var config = ConfigFile() {
        didSet {
            guard config != oldValue else { return }
            if !isReloading { save() }
            // Not while loading in init: applying it reads SettingsStore.shared, which isn't
            // ready yet. The app delegate applies it once launch finishes.
            if isLoaded { AppSettings.applyDockIconPolicy() }
        }
    }
    /// Why the file couldn't be read or written, shown in Settings.
    private(set) var error: String?

    @ObservationIgnored private var isReloading = false
    @ObservationIgnored private var isLoaded = false
    /// True while the file on disk can't be read: saving then would overwrite the user's edits.
    @ObservationIgnored private var fileIsBroken = false
    @ObservationIgnored private var watcher: FolderWatcher?

    private init() {
        ConfigFolder.ensureExists()
        if FileManager.default.fileExists(atPath: ConfigFolder.configFile.path) {
            reload()
        } else {
            // Saved once, here: didSet would also save, but skips a value equal to the
            // defaults, so it can't be relied on to create the file.
            isReloading = true
            config = Self.migratedFromUserDefaults()
            isReloading = false
            save()
        }
        watcher = FolderWatcher(ConfigFolder.url) { [weak self] in self?.reload() }
        isLoaded = true
    }

    /// Re-reads config.json, e.g. after it was edited outside Cheetsheet.
    func reload() {
        guard let data = try? Data(contentsOf: ConfigFolder.configFile) else { return }
        do {
            let loaded = try JSONDecoder().decode(ConfigFile.self, from: data)
            isReloading = true
            config = loaded
            isReloading = false
            fileIsBroken = false
            error = nil
        } catch {
            fileIsBroken = true
            self.error = "config.json couldn't be read, so Cheetsheet isn't saving changes to it: \(Self.describe(error))"
        }
    }

    private func save() {
        guard !fileIsBroken else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try ConfigFolder.write(try encoder.encode(config), to: ConfigFolder.configFile)
            error = nil
        } catch {
            self.error = "Couldn't save config.json: \(error.localizedDescription)"
        }
    }

    /// Carries settings over from earlier versions, which kept them in macOS's preferences.
    private static func migratedFromUserDefaults() -> ConfigFile {
        let defaults = UserDefaults.standard
        var config = ConfigFile()
        if let raw = defaults.string(forKey: "triggerKey"), let key = TriggerKey(rawValue: raw) { config.trigger = key }
        if defaults.double(forKey: "holdDelay") > 0 { config.holdDelay = defaults.double(forKey: "holdDelay") }
        if let show = defaults.object(forKey: "showMenuBarIcon") as? Bool { config.showMenuBarIcon = show }
        config.hideTerminalShortcuts = defaults.bool(forKey: "hideHostMenus")
        return config
    }

    /// A short, readable reason a JSON file couldn't be decoded.
    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context):
            return (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
                ?? context.debugDescription
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(path): \(context.debugDescription)"
        case DecodingError.keyNotFound(let key, _):
            return "missing \"\(key.stringValue)\""
        default:
            return error.localizedDescription
        }
    }
}
