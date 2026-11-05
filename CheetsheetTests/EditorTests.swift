import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Cheetsheet

/// The sheet editor's draft model and key recording.
struct EditorTests {
    @Test func everyBuiltInSheetSurvivesTheEditorUnchanged() throws {
        for sheet in try SheetTests.builtInSheets() {
            let saved = SheetDraft(sheet).makeSheet(id: sheet.id)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let reloaded = try JSONDecoder().decode(Cheatsheet.self, from: encoder.encode(saved))
            #expect(reloaded == sheet, "\(sheet.id) changed after a save")
        }
    }

    @Test func newSheetChecksAndActions() {
        var draft = SheetDraft()
        #expect(draft.problems == ["Give the sheet a name."])

        draft.name = "My Keys"
        draft.sections[0].entries = [
            .init(keysText: "⌃⌥⌘H", description: "Move left", note: ""),
            .init(keysText: "⌃⌥⌘L", description: "Move left", note: " hi "),
            .init(keysText: "", description: "", note: ""),
        ]
        #expect(draft.problems.isEmpty)

        let entries = draft.makeSheet(id: "my-keys").sections[0].entries
        #expect(entries.map(\.action) == ["move-left", "move-left-2"])  // unique
        #expect(entries.count == 2)                                       // blank row dropped
        #expect(entries[0].note == nil && entries[1].note == "hi")       // trimmed

        draft.sections[0].entries[0].keysText = ""
        #expect(draft.problems == ["An entry in “General” has no keys."])
        draft.sections[0].entries[0].keysText = "x"

        draft.showMode = .terminal
        draft.titlePattern = #"\b(unclosed"#
        #expect(draft.problems == ["The window title pattern isn't a valid regular expression."])

        draft.showMode = .apps
        #expect(draft.problems.first?.hasPrefix("Add at least one app") == true)

        draft.showMode = .everywhere
        draft.sections.append(.init(title: "General", entries: []))
        #expect(draft.problems == ["Two sections are called “General”."])
    }

    @Test(arguments: [
        (#"⌃w "h j k l"  x"#, ["⌃w", "h j k l", "x"]),
        (#"{prefix} ""#, ["{prefix}", "\""]),          // tmux's " key on its own
        (#"" x ""#, ["\"", "x", "\""]),               // quotes with spaces after aren't quoting
        (#"⇧" ⌘""#, ["⇧\"", "⌘\""]),                   // a quote inside a keycap
        (#"":e {file}""#, [":e {file}"]),
        ("", []),
    ])
    func keysParse(text: String, keys: [String]) {
        #expect(SheetDraft.EntryDraft.parse(text) == keys)
    }

    @Test func keysFormatRoundTrips() {
        let keys = ["⌃w", "h j k l", "\"", "{prefix}"]
        #expect(SheetDraft.EntryDraft.parse(SheetDraft.EntryDraft.format(keys)) == keys)
    }

    @Test func slug() {
        #expect("Move window left!".slug == "move-window-left")
        #expect("  ".slug == "")
    }

    private func press(_ code: Int, _ characters: String, _ flags: NSEvent.ModifierFlags) throws -> [String] {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
        return KeyRecorder.keycaps(for: event)
    }

    @Test func recordedKeycaps() throws {
        #expect(try press(kVK_ANSI_H, "h", [.control, .option, .command]) == ["⌃", "⌥", "⌘", "H"])
        #expect(try press(kVK_ANSI_D, "D", [.shift, .command]) == ["⇧", "⌘", "D"])
        #expect(try press(kVK_ANSI_G, "G", [.shift]) == ["G"])      // vim-style: shift is in the letter
        #expect(try press(kVK_ANSI_G, "g", []) == ["g"])
        #expect(try press(kVK_ANSI_4, "$", [.shift]) == ["$"])
        #expect(try press(kVK_Return, "\r", [.shift]) == ["⇧", "↩"])
        #expect(try press(kVK_LeftArrow, "\u{F702}", [.option, .command]) == ["⌥", "⌘", "←"])
        #expect(try press(kVK_Space, " ", []) == ["Space"])
        #expect(try press(kVK_ANSI_B, "b", [.control]) == ["⌃", "B"])
    }
}
