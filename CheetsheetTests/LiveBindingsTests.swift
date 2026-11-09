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

struct VimRunTests {
    @Test(.enabled(if: ProcessRunner.find("vim") != nil))
    func pluginsAddedByTheVimrcAreNotYours() throws {
        // Like vim-plug: the vimrc adds a plugin folder to the runtimepath.
        let folder = try TemporaryFolder()
        let plugin = folder.url.appending(path: "surround/plugin")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try "nnoremap ys :echo 'surround'<CR>\n".write(to: plugin.appending(path: "surround.vim"), atomically: true, encoding: .utf8)
        let vimrc = folder.url.appending(path: "vimrc")
        try "set rtp+=\(folder.url.appending(path: "surround").path)\nnnoremap <Space>w :w<CR>\n"
            .write(to: vimrc, atomically: true, encoding: .utf8)

        let vim = try #require(ProcessRunner.find("vim"))
        let lists = try #require(VimBindings.readLists(vim: vim, vimrc: vimrc))
        let yours = Set(lists.user).subtracting(lists.defaults).map(\.lhs)
        #expect(yours == ["<Space>w"])
    }
}

struct HerdrTests {
    // The shape `herdr --default-config` prints: every setting commented out.
    let defaults = HerdrBindings.parse(HerdrBindings.uncommented(#"""
    [keys]
    # Prefix key to enter prefix mode (default: "ctrl+b")
    # prefix = "ctrl+b"
    # next_tab = "prefix+n"
    # new_workspace = "prefix+shift+n"
    # split_vertical = "prefix+v"
    # split_horizontal = "prefix+minus"
    # close_pane = "prefix+x"
    # last_pane = ""          # optional, unset by default
    # [[keys.command]]
    # type = "shell" runs detached in the background.
    # key = "prefix+alt+g"
    # command = "lazygit"
    """#))

    func resolve(_ user: String) throws -> LiveBindings {
        HerdrBindings.resolve(sheet: try SheetTests.sheet("herdr"), defaults: defaults,
                              user: HerdrBindings.parse(user), source: "test")
    }

    @Test func defaultsAreReadFromComments() {
        #expect(defaults.actions["prefix"] == ["ctrl+b"])
        #expect(defaults.actions["split_horizontal"] == ["prefix+minus"])
        #expect(defaults.actions["last_pane"] == [])
        // Prose that starts like a setting stays a comment.
        #expect(defaults.actions["type"] == nil)
        #expect(defaults.commands.count == 1)
    }

    @Test func prefixAddedKeysAndExtras() throws {
        let live = try resolve(#"""
        [theme]
        name = "catppuccin"

        [keys]
        prefix = ["ctrl+space", "ctrl+s"]
        split_vertical = "prefix+backslash"     # replaces v
        split_horizontal = [
          "prefix+minus",
          "prefix+shift+minus",
        ]
        last_pane = "prefix+tab"

        [[keys.command]]
        key = "prefix+alt+g"
        type = "popup"
        command = "lazygit"
        description = "Git"

        [ui]
        window_title = "x # not a comment"
        """#)
        #expect(live.prefix == "⌃space")

        // v is gone and \ does its job.
        let moved = try #require(live.overrides["split_vertical"])
        #expect(moved.keys == ["⌃space", "\\"] && !moved.defaultStillWorks && moved.note == nil)

        // - still works and ⇧- was added.
        let added = try #require(live.overrides["split_horizontal"])
        #expect(added.keys == ["⌃space", "⇧-"] && added.defaultStillWorks)

        // last_pane isn't on the sheet, so it's one of their bindings, as is the command.
        #expect(live.extras.map(\.title) == ["Last pane", "Git"])
        #expect(live.extras.map(\.keys) == [["⌃space", "⇥"], ["⌃space", "⌥g"]])
    }

    @Test func unboundAndTakenDefaults() throws {
        var live = try resolve("[keys]\nclose_pane = \"\"")
        #expect(live.overrides["close_pane"]?.note == "Unbound")

        // herdr gives the key to your binding and drops the default that had it.
        live = try resolve("[keys]\nsplit_vertical = \"prefix+n\"")
        #expect(live.overrides["next_tab"]?.note == "Key now runs Split vertical")
        #expect(live.overrides["split_vertical"]?.keys == ["⌃b", "n"])

        // Two of yours on one key: always the same one is named.
        live = try resolve("[keys]\nsplit_vertical = \"prefix+n\"\nlast_pane = \"prefix+n\"")
        #expect(live.overrides["next_tab"]?.note == "Key now runs Last pane")

        // A custom command on a default key takes it too.
        live = try resolve("[keys]\n[[keys.command]]\nkey = \"prefix+v\"\ncommand = \"lazygit\"")
        #expect(live.overrides["split_vertical"]?.note == "Key now runs lazygit")
        #expect(live.overrides["split_vertical"]?.defaultStillWorks == false)

        // "prefix+N" is the same key as the default "prefix+shift+n".
        live = try resolve("[keys]\nsplit_vertical = \"Prefix+N\"")
        #expect(live.overrides["new_workspace"]?.note == "Key now runs Split vertical")
        #expect(live.overrides["split_vertical"]?.keys == ["⌃b", "N"])
    }

    @Test func bracketKeysDontEndAnArray() {
        let keys = HerdrBindings.parse(#"""
        [keys]
        next_tab = [ "prefix+]",
          "prefix+n",
        ]
        previous_tab = [
          "prefix+[",
          "prefix+p",
        ]
        close_pane = "prefix+x"
        """#)
        #expect(keys.actions["next_tab"] == ["prefix+]", "prefix+n"])
        #expect(keys.actions["previous_tab"] == ["prefix+[", "prefix+p"])
        #expect(keys.actions["close_pane"] == ["prefix+x"])
    }

    @Test func keySpellingsAreNormalised() {
        #expect(HerdrBindings.normalised("prefix+N") == "prefix+shift+n")
        #expect(HerdrBindings.normalised("Shift+Ctrl+A") == "ctrl+shift+a")
        #expect(HerdrBindings.normalised("cmd++") == "super+plus")
        #expect(HerdrBindings.normalised("option+Return") == "alt+enter")
        #expect(HerdrBindings.normalised("1..9") == "1..9")
    }

    @Test func everyAddedKeyIsShown() throws {
        let live = try resolve(#"""
        [keys]
        split_horizontal = ["prefix+minus", "prefix+shift+minus", "prefix+backslash"]
        """#)
        #expect(live.overrides["split_horizontal"]?.keys == ["⌃b", "⇧-"])
        #expect(live.extras.map(\.title) == ["Split top and bottom"])
        #expect(live.extras.map(\.keys) == [["⌃b", "\\"]])
    }

    @Test func sheetActionsWithoutAPrintedDefaultAreListed() throws {
        // herdr 0.9.5 doesn't print copy_mode's default, so there's nothing to compare with.
        let live = try resolve("[keys]\ncopy_mode = \"prefix+y\"")
        #expect(live.overrides["copy_mode"] == nil)
        #expect(live.extras.map(\.title) == ["Copy mode"])
    }

    @Test func untouchedConfigChangesNothing() throws {
        let live = try resolve("[keys]\nprefix = \"ctrl+b\"\nnext_tab = \"prefix+n\"")
        #expect(live.prefix == nil && live.overrides.isEmpty && live.extras.isEmpty)
    }

    @Test func keyNames() {
        #expect(HerdrBindings.display("ctrl+a") == "⌃a")
        #expect(HerdrBindings.display("shift+n") == "N")
        #expect(HerdrBindings.display("shift+tab") == "⇧⇥")
        #expect(HerdrBindings.display("ctrl+alt+left") == "⌃⌥←")
        #expect(HerdrBindings.display("cmd++") == "⌘+")
        #expect(HerdrBindings.display("1..9") == "1–9")
    }

    @Test func everySheetKeyMatchesHerdrsDefault() throws {
        // The sheet's keycaps must be what herdr's defaults display as, or every entry
        // would look changed. These are the defaults from herdr 0.9.5.
        let sheet = try SheetTests.sheet("herdr")
        let herdrDefaults = [
            "detach": "q", "goto": "g", "workspace_picker": "w", "new_workspace": "shift+n",
            "new_worktree": "shift+g", "rename_workspace": "shift+w", "close_workspace": "shift+d",
            "open_notification_target": "o", "new_tab": "c", "rename_tab": "shift+t", "next_tab": "n",
            "previous_tab": "p", "switch_tab": "1..9", "close_tab": "shift+x", "split_vertical": "v",
            "split_horizontal": "minus", "focus_pane_left": "h", "focus_pane_down": "j",
            "focus_pane_up": "k", "focus_pane_right": "l", "cycle_pane_next": "tab",
            "cycle_pane_previous": "shift+tab", "swap_pane_left": "shift+h", "swap_pane_down": "shift+j",
            "swap_pane_up": "shift+k", "swap_pane_right": "shift+l", "zoom": "z", "resize_mode": "r",
            "rename_pane": "shift+p", "close_pane": "x", "copy_mode": "[", "edit_scrollback": "e",
            "help": "?", "settings": "s", "toggle_sidebar": "b", "reload_config": "shift+r",
        ]
        for entry in sheet.sections.flatMap(\.entries) where entry.keys.first == "{prefix}" {
            let key = try #require(herdrDefaults[entry.action], "\(entry.action)")
            #expect(entry.keys == ["{prefix}", HerdrBindings.display(key)], "\(entry.action)")
        }
    }
}

struct TerminalConfigTests {
    let herdr = TerminalConfig.all.first { $0.id == "herdr" }!
    let tmux = TerminalConfig.all.first { $0.id == "tmux" }!

    func herdrChange(_ text: String) -> String? { herdr.change(text, herdr.lines("toml"))?.updated }
    func tmuxChange(_ text: String) -> String? { tmux.change(text, tmux.lines("conf"))?.updated }

    @Test func herdrLinesGoIntoTheUITable() throws {
        let updated = try #require(herdrChange("[ui]\nsidebar_width = 30\n"))
        #expect(updated.hasPrefix("[ui]\n# Added by Cheetsheet"))
        #expect(updated.contains("— herdr\"\nsidebar_width = 30\n"))
    }

    @Test func herdrLinesAddAUITableWhenThereIsNone() throws {
        let text = "[ui.toast]\ndelivery = \"system\""
        let updated = try #require(herdrChange(text))
        #expect(updated.hasPrefix(text + "\n\n[ui]\n"))
    }

    @Test func herdrExistingWindowTitleGetsHerdrAdded() {
        #expect(herdrChange("[ui]\nwindow_title = \"{workspace}\"  # mine\n")
                == "[ui]\nwindow_title = \"{workspace} — herdr\"  # mine\n")
        #expect(herdrChange("[ui]\nwindow_title = '{workspace}'\n") == "[ui]\nwindow_title = '{workspace} — herdr'\n")
        // A multi-line string is left for you to edit.
        #expect(herdrChange("[ui]\nwindow_title = \"\"\"\n{workspace}\n\"\"\"\n") == nil)
    }

    @Test func herdrUITableWithoutAHeaderIsLeftAlone() {
        // Adding a [ui] header here would define the table twice and break the file.
        #expect(herdrChange("ui = { sidebar_width = 30 }\n") == nil)
        #expect(herdrChange("ui.sidebar_width = 30\n") == nil)
    }

    @Test func tmuxLinesAreAddedWhenThereAreNone() {
        #expect(tmuxChange("set -g mouse on\n") == "set -g mouse on\n" + tmux.lines("conf"))
    }

    @Test func tmuxExistingTitleKeepsItsFormat() throws {
        let updated = try #require(tmuxChange("set -g set-titles on\nset -g set-titles-string \"#S: #W\"\n"))
        #expect(updated == "set -g set-titles on\nset -g set-titles-string \"#S: #W — tmux\"\n")

        // set-titles on is added at the end, after any "off".
        let both = try #require(tmuxChange("set -g set-titles-string '#W'\nset -g set-titles off\n"))
        #expect(both.hasPrefix("set -g set-titles-string '#W — tmux'\nset -g set-titles off\n"))
        #expect(both.hasSuffix("set -g set-titles on\n"))
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
        // The same symbols as menus, so menu shortcuts aren't listed twice.
        #expect(GhosttyBindings.display("super+page_up") == ["⌘", "⇞"])
        #expect(GhosttyBindings.display("escape") == ["⎋"])
        #expect(GhosttyBindings.display("ctrl+space") == ["⌃", "Space"])
        #expect(GhosttyBindings.display("super+f5") == ["⌘", "F5"])
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
