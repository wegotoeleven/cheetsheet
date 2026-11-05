import Foundation

/// A sheet being edited. Separate from `Cheatsheet` because the form needs things the
/// saved file doesn't: stable row IDs while titles are typed, keys as editable text, and
/// the settings for every "show" option so switching between them doesn't lose what you typed.
struct SheetDraft: Identifiable {
    enum ShowMode: String, CaseIterable, Identifiable {
        case mainWindow, everywhere, apps, terminal
        var id: Self { self }
        var label: String {
            switch self {
            case .mainWindow: "Main window only"
            case .everywhere: "Everywhere"
            case .apps: "In chosen apps"
            case .terminal: "Inside a terminal"
            }
        }
    }

    struct SectionDraft: Identifiable {
        let id = UUID()
        var title: String
        var entries: [EntryDraft]
    }

    struct EntryDraft: Identifiable {
        let id = UUID()
        /// Kept from the file so live tmux bindings still match; made up for new entries.
        var action: String?
        /// Keycaps separated by spaces, e.g. "⌃⌥⌘H" or "{prefix} %". A keycap that itself
        /// contains spaces goes in quotes: `":e {file}"`.
        var keysText: String
        var description: String
        var note: String

        var keys: [String] { Self.parse(keysText) }

        static func format(_ keys: [String]) -> String {
            keys.map { $0.contains(where: \.isWhitespace) ? "\"\($0)\"" : $0 }.joined(separator: " ")
        }

        /// Splits on spaces, except inside "quotes". A quote only opens a quoted keycap when
        /// text follows it directly, so tmux's `"` key on its own stays a key.
        static func parse(_ text: String) -> [String] {
            let chars = Array(text)
            var keys: [String] = [], i = 0
            while i < chars.count {
                if chars[i].isWhitespace { i += 1; continue }
                if chars[i] == "\"", i + 1 < chars.count, !chars[i + 1].isWhitespace,
                   // the closing quote: one that ends a word
                   let close = (i + 1..<chars.count).first(where: { j in
                       chars[j] == "\"" && !chars[j - 1].isWhitespace
                           && (j + 1 == chars.count || chars[j + 1].isWhitespace) }) {
                    keys.append(String(chars[(i + 1)..<close]))
                    i = close + 1
                    continue
                }
                var j = i
                while j < chars.count && !chars[j].isWhitespace { j += 1 }
                keys.append(String(chars[i..<j]))
                i = j
            }
            return keys
        }
        var isBlank: Bool { keys.isEmpty && description.trimmed.isEmpty && note.trimmed.isEmpty }
    }

    let id = UUID()
    /// The sheet's id when editing an existing one; nil for a new sheet.
    let originalID: String?
    var name: String
    var symbol: String
    var showMode: ShowMode
    var apps: [String]
    var titlePattern: String
    var sections: [SectionDraft]
    // Not in the form, but kept so saving doesn't drop them.
    let prefix: String?
    let layer: Int?

    var isNew: Bool { originalID == nil }

    /// A new, nearly empty sheet.
    init() {
        originalID = nil
        name = ""
        symbol = "list.bullet.rectangle"
        showMode = .everywhere
        apps = []
        titlePattern = ""
        sections = [SectionDraft(title: "General", entries: [EntryDraft(keysText: "", description: "", note: "")])]
        prefix = nil
        layer = nil
    }

    /// An existing sheet, built-in or yours.
    init(_ sheet: Cheatsheet) {
        originalID = sheet.id
        name = sheet.name
        symbol = sheet.symbol
        apps = []
        titlePattern = ""
        switch sheet.show {
        case nil: showMode = .mainWindow
        case .everywhere: showMode = .everywhere
        case .apps(let ids): showMode = .apps; apps = ids
        case .terminalTitle(let pattern): showMode = .terminal; titlePattern = pattern
        }
        sections = sheet.sections.map { section in
            SectionDraft(title: section.title, entries: section.entries.map {
                EntryDraft(action: $0.action, keysText: EntryDraft.format($0.keys),
                           description: $0.description, note: $0.note ?? "")
            })
        }
        prefix = sheet.prefix
        layer = sheet.layer
    }

    /// What has to be fixed before saving, in plain words. Empty when it's ready.
    var problems: [String] {
        var problems: [String] = []
        if name.trimmed.isEmpty { problems.append("Give the sheet a name.") }
        switch showMode {
        case .apps where apps.isEmpty:
            problems.append("Add at least one app, or choose another option under “Shows up”.")
        case .terminal:
            if titlePattern.trimmed.isEmpty {
                problems.append("Enter a window title pattern.")
            } else if !SheetDraft.isValidPattern(titlePattern) {
                problems.append("The window title pattern isn't a valid regular expression.")
            }
        default: break
        }
        var titles: Set<String> = []
        for section in sections {
            let title = section.title.trimmed
            if title.isEmpty { problems.append("Every section needs a title."); continue }
            if !titles.insert(title).inserted { problems.append("Two sections are called “\(title)”.") }
            for entry in section.entries where !entry.isBlank {
                if entry.keys.isEmpty { problems.append("An entry in “\(title)” has no keys.") }
                if entry.description.trimmed.isEmpty { problems.append("An entry in “\(title)” has no description.") }
            }
        }
        // The same problem in several entries only needs saying once.
        var seen: Set<String> = []
        return problems.filter { seen.insert($0).inserted }
    }

    /// The sheet to save. Blank entries are left out. New entries get an `action` id made
    /// from their description, unique within the sheet.
    func makeSheet(id: String) -> Cheatsheet {
        var usedActions = Set(sections.flatMap(\.entries).compactMap(\.action))
        func newAction(for description: String) -> String {
            let base = description.slug.isEmpty ? "entry" : description.slug
            var action = base, n = 2
            while usedActions.contains(action) { action = "\(base)-\(n)"; n += 1 }
            usedActions.insert(action)
            return action
        }

        let show: Cheatsheet.Show? = switch showMode {
        case .mainWindow: nil
        case .everywhere: .everywhere
        case .apps: .apps(apps)
        case .terminal: .terminalTitle(titlePattern.trimmed)
        }
        return Cheatsheet(
            id: id, name: name.trimmed, symbol: symbol.trimmed.isEmpty ? "list.bullet.rectangle" : symbol.trimmed,
            prefix: prefix, show: show, layer: layer,
            sections: sections.map { section in
                Cheatsheet.Section(title: section.title.trimmed, entries: section.entries.filter { !$0.isBlank }.map { entry in
                    Cheatsheet.Entry(action: entry.action ?? newAction(for: entry.description),
                                     keys: entry.keys, description: entry.description.trimmed,
                                     note: entry.note.trimmed.isEmpty ? nil : entry.note.trimmed)
                })
            })
    }

    static func isValidPattern(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }
}

nonisolated extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Lowercase letters and digits joined by dashes: "Move window left" → "move-window-left".
    var slug: String {
        String(lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
    }
}
