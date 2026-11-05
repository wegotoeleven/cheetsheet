import Foundation
import Testing
@testable import Cheetsheet

/// Comparing real configs with each program's defaults. These use saved program output,
/// so they don't need tmux, vim or Ghostty installed.
struct TmuxTests {
    let defaults = #"""
    bind-key    -T prefix       C-b                  send-prefix
    bind-key    -T prefix       %                    split-window -h
    bind-key    -T prefix       \"                   split-window
    """#

    func resolve(_ user: String) throws -> LiveBindings {
        TmuxBindings.resolve(sheet: try SheetTests.sheet("tmux"), defaults: defaults, user: user, source: "test")
    }

    @Test func prefixAddedKeysAndExtras() throws {
        let live = try resolve(#"""
        bind-key    -T prefix       C-a                  send-prefix
        bind-key    -T prefix       \"                   split-window
        bind-key    -T prefix       -                    split-window
        bind-key    -T prefix       |                    split-window -h
        bind-key    -T prefix       r                    source-file ~/.tmux.conf
        prefix C-a
        @prefix r  Reload config
        """#)
        #expect(live.prefix == "⌃a")

        // % is gone and | does its job: struck through, pointing at the new key.
        let moved = try #require(live.overrides["split-window -h"])
        #expect(moved.keys == ["⌃a", "|"] && !moved.defaultStillWorks && moved.note == nil)

        // " still works and - was added: - first, " greyed.
        let added = try #require(live.overrides["split-window"])
        #expect(added.keys == ["⌃a", "-"] && added.defaultStillWorks)

        // Their other binding, titled with its note; send-prefix isn't listed.
        #expect(live.extras.map(\.title) == ["Reload config"])
        #expect(live.extras.first?.keys == ["⌃a", "r"])
    }

    @Test func unboundAndReboundDefaults() throws {
        var live = try resolve(#"bind-key    -T prefix       \"                   split-window"#)
        #expect(live.overrides["split-window -h"]?.note == "Unbound")

        live = try resolve(#"""
        bind-key    -T prefix       %                    kill-pane
        bind-key    -T prefix       \"                   split-window
        """#)
        #expect(live.overrides["split-window -h"]?.note == "Key now runs kill-pane")
    }

    @Test func untouchedConfigChangesNothing() throws {
        let live = try resolve(defaults)
        #expect(live.prefix == nil && live.overrides.isEmpty && live.extras.isEmpty)
    }

    @Test func keyNames() {
        #expect(TmuxBindings.display("C-a") == "⌃a")
        #expect(TmuxBindings.display("M-Up") == "⌥↑")
        #expect(TmuxBindings.display("C-M-S-Left") == "⌃⌥⇧←")
        #expect(TmuxBindings.display("-") == "-")
    }
}

struct GhosttyTests {
    let defaults = """
    keybind = super+d=new_split:right
    keybind = super+shift+j=write_screen_file:paste,plain
    keybind = super+alt+arrow_left=goto_split:left
    keybind = super+==increase_font_size:1
    keybind = copy=copy_to_clipboard:mixed
    """

    @Test func customBindingsShowWhatTheyReplaceAndWhatStillWorks() throws {
        let user = defaults + """

        keybind = super+shift+h=goto_split:left
        keybind = super+shift+j=new_split:down
        """
        let items = GhosttyBindings.resolve(defaults: defaults, user: user).items

        let left = try #require(items.first { $0.keys == ["⇧", "⌘", "H"] })
        #expect(left.isCustom && left.title == "Go to split (left)")
        #expect(left.alsoWorks == ["⌥", "⌘", "←"])

        let down = try #require(items.first { $0.keys == ["⇧", "⌘", "J"] })
        #expect(down.note == "Replaces: Write screen file (paste, plain)")

        // The default ⌥⌘← is shown greyed beside ⇧⌘H, not again on its own.
        #expect(!items.contains { $0.keys == ["⌥", "⌘", "←"] })
        // Dedicated Copy/Paste keys are left out.
        #expect(!items.contains { $0.title.hasPrefix("Copy") })
    }

    @Test func parsing() {
        let bindings = GhosttyBindings.parse("keybind = super+==increase_font_size:1\nkeybind = global:ctrl+a>n=new_window\nnot a binding")
        #expect(bindings.map(\.trigger) == ["super+=", "global:ctrl+a>n"])
        #expect(GhosttyBindings.display("super++") == ["⌘", "+"])
        #expect(GhosttyBindings.display("global:ctrl+a>n") == ["⌃", "A", "N"])
        #expect(GhosttyBindings.display("super+digit_1") == ["⌘", "1"])
        #expect(GhosttyBindings.describe(#"text:\x01"#) == "Start of line")
    }
}

struct VimTests {
    typealias Mapping = VimBindings.Mapping
    let defaults = [Mapping(mode: "n", lhs: "gx", rhs: "<Plug>(open-word-under-cursor)")]

    @Test func yourMappingsAndRemappedSheetKeys() throws {
        let user = defaults + [
            Mapping(mode: "n", lhs: "<C-D>", rhs: "<C-D>zz"),
            Mapping(mode: "n", lhs: "<Space>ff", rhs: ":Files<CR>"),
            Mapping(mode: "x", lhs: "<Space>y", rhs: "\"+y"),
            Mapping(mode: "v", lhs: "<Space>y", rhs: "\"+y"),
            Mapping(mode: "i", lhs: "jk", rhs: "<Esc>"),
            Mapping(mode: "n", lhs: "<Plug>(mine)", rhs: ":echo<CR>"),
            Mapping(mode: "n", lhs: "s", rhs: "<Plug>(my-sneak)"),
        ]
        let live = VimBindings.resolve(sheet: try SheetTests.sheet("vim"), defaults: defaults, user: user, source: "~/.vimrc")

        // ⌃d is on the Vim sheet, and the vimrc changed it (case doesn't matter for Ctrl keys).
        #expect(live.overrides["normal:<C-d>"]?.note == "Key now runs <C-D>zz")

        let byKeys = Dictionary(uniqueKeysWithValues: live.extras.map { ($0.keys, $0) })
        #expect(byKeys[["Space", "f", "f"]]?.title == "Files")
        #expect(byKeys[["Space", "y"]]?.note == "Visual mode")        // x and v merged into one row
        #expect(byKeys[["j", "k"]]?.note == "Insert mode")
        #expect(byKeys[["s"]]?.title == "my sneak")
        #expect(byKeys[["g", "x"]] == nil)                              // Vim's own default
        #expect(!live.extras.contains { $0.keys.first == "<Plug>(mine)" }) // <Plug> targets aren't keys
        #expect(live.extras.count == 5)
    }

    @Test func keyNotation() {
        #expect(VimBindings.keycaps("<Space>ff") == ["Space", "f", "f"])
        #expect(VimBindings.keycaps("<C-D>") == ["⌃d"])
        #expect(VimBindings.keycaps("<C-S-Tab>") == ["⌃⇧⇥"])
        #expect(VimBindings.keycaps("<lt>a") == ["<", "a"])
        #expect(VimBindings.keycaps("<C-->") == ["⌃-"])
        #expect(VimBindings.keycaps("a<b") == ["a", "<", "b"])
        #expect(VimBindings.describe("<Cmd>w<CR>") == "w")
        #expect(VimBindings.describe("<Nop>") == "Does nothing")
    }
}
