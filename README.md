# Cheetsheet

A macOS menu bar app that shows the keyboard shortcuts for whatever you are using when you hold down a modifier key.

## What is this?

Cheetsheet is a native Swift and SwiftUI app for macOS. Hold a key such as ⌘ and an overlay appears with the shortcuts for the app in front of you. It reads them from the app's menus, so it works with any app.

Inside a terminal, it reads the window title to tell when tmux or Vim is running and shows their sheets as well. It reads your real configuration and marks every binding you have changed.

You can also write your own cheatsheets as JSON or make them in the built-in editor. Everything you configure lives in `~/.config/cheetsheet`, so it can go in your dotfiles.

It includes:

- **An overlay for any app**, built from the front app's menus using the Accessibility API.
- **Live bindings for tmux, Vim and Ghostty**, compared against each program's defaults. A default you have removed or remapped is struck through. A default that still works alongside a key you added is greyed out.
- **Built-in tmux and Vim sheets.** Your prefix key is substituted into the tmux sheet.
- **Your own sheets.** Each one says where it appears: everywhere, in chosen apps, or inside a terminal when the window title matches a pattern.
- **A sheet editor** that records keys as you press them and saves plain JSON.
- **A main window** with a searchable view of every sheet and the current app's menu shortcuts.
- **Launch at login** and an optional menu bar icon.

## Why does it exist?

Keyboard shortcuts are spread across app menus, terminal multiplexers, editors and dotfiles. Most cheatsheet tools show fixed lists that ignore your own configuration.

Cheetsheet reads what is actually in effect on your machine. That means each app's menus, your running tmux server or `tmux.conf`, your `vimrc`, and your Ghostty config. It shows those bindings next to the defaults, so a sheet never lists a key that no longer works for you.

Reading other apps' menus requires the Accessibility API, which rules out the App Sandbox. So Cheetsheet is distributed outside the Mac App Store.

## How do I install it?

Prerequisites:

- macOS 26 or later
- Xcode 26 or later (the app icon uses the Icon Composer format)
- Optional: tmux, Vim and Ghostty, for live bindings

Clone the repository and build the Release configuration:

```bash
git clone <repository-url> cheetsheet
```

```bash
cd cheetsheet
```

```bash
xcodebuild -project Cheetsheet.xcodeproj -target Cheetsheet -configuration Release build
```

The app is written to `build/Release/Cheetsheet.app`. Copy it to `/Applications`:

```bash
cp -R build/Release/Cheetsheet.app /Applications/
```

You can also open `Cheetsheet.xcodeproj` in Xcode and run the `Cheetsheet` scheme.

## How do I run it?

Open Cheetsheet from `/Applications`. On first launch it asks for Accessibility access, which it needs to read other apps' menus and to notice the trigger key being held. Grant it in System Settings → Privacy & Security → Accessibility.

The command above leaves the app ad hoc signed, so macOS treats each new build as a different app. Grant Accessibility access again after every rebuild, or sign the app with the same certificate each time to keep the permission.

All settings are stored in `~/.config/cheetsheet/config.json`, which is created on first launch. Change them in Settings (⌘,) or edit the file directly. Cheetsheet picks up edits while it runs. Any key you leave out uses its default:

```json
{
  "hideTerminalShortcuts" : false,
  "holdDelay" : 0.8,
  "showMenuBarIcon" : true,
  "trigger" : "command"
}
```

| Key | Values | Meaning |
|---|---|---|
| `trigger` | `command`, `option`, `control`, `shift` | The modifier you hold to show the overlay |
| `holdDelay` | seconds | How long to hold it before the overlay appears |
| `showMenuBarIcon` | `true`, `false` | With the icon hidden, Cheetsheet stays in the Dock instead |
| `hideTerminalShortcuts` | `true`, `false` | Hide the terminal app's own shortcuts when tmux or Vim is detected |

"Open at login" is in Settings → App. It is not stored in `config.json`, because macOS keeps that setting itself under System Settings → General → Login Items.

## How do I use it?

### The overlay

Hold the trigger key (⌘ by default) on its own for the hold delay. The overlay shows one column of shortcuts per layer, in this order:

1. Sheets for programs detected inside the terminal, innermost first (for example Vim, then tmux), with a breadcrumb such as `Ghostty › tmux › Vim`.
2. The front app's menu shortcuts, plus any bindings from its config file that have no menu item (currently Ghostty).
3. Your sheets attached to the front app.
4. Your sheets set to show everywhere.

Release the key to close the overlay. Pressing another key or clicking while you hold it cancels the overlay, so ordinary shortcuts such as ⌘C never open it.

When a binding differs from the default, the overlay shows a legend:

- **Struck through:** a default you have removed or rebound. A note says "Unbound" or what the key does now.
- **Greyed out:** a default that still works, shown after the key you added for the same action.

### Detecting tmux and Vim in a terminal

Cheetsheet reads the terminal window's title, so tmux and Vim need to put their names in it. Settings → Terminals checks your config files and can add the lines for you. To add them yourself:

```sh
# ~/.tmux.conf
set -g set-titles on
set -g set-titles-string "#T — tmux"
```

```vim
" ~/.vimrc
set title
```

```lua
-- ~/.config/nvim/init.lua
vim.opt.title = true
```

Detection works in Ghostty, Terminal, iTerm2, kitty, Alacritty and WezTerm, including over SSH. Live bindings always come from your Mac. On a remote machine, you see your Mac's tmux and Vim bindings, not the remote machine's.

### Live bindings

| Source | How Cheetsheet reads it |
|---|---|
| tmux | Runs `tmux list-keys` against your running server, or loads your config on a private socket if no server is running. Compares the result with `tmux -f /dev/null`. |
| Vim | Runs `vim` once with your vimrc and once without it, and treats mappings that appear only with your vimrc as yours. |
| Ghostty | Compares `ghostty +list-keybinds` with `ghostty +list-keybinds --default`. |

Your extra bindings appear in a "Your bindings" section. Bindings are re-read when you open the overlay, at most once every five seconds.

### The main window

Open it from the menu bar icon or the Dock. The sidebar lists:

- **Current app:** the menu shortcuts of the last app you used.
- **Every sheet**, labelled with where it appears in the overlay.

Each sheet page has section filters and a search field.

### Your own sheets

Put JSON files in `~/.config/cheetsheet/sheets/`. Cheetsheet loads them, and reloads them when files change, without a restart. A sheet with the same `id` as a built-in sheet (`tmux` or `vim`) replaces it.

```json
{
  "id": "window-keys",
  "name": "Window keys",
  "symbol": "macwindow",
  "show": "everywhere",
  "sections": [
    {
      "title": "Windows",
      "entries": [
        { "action": "window-left", "keys": ["⌃", "⌥", "⌘", "H"], "description": "Move window left" },
        { "action": "caps-esc", "keys": ["⇪"], "description": "Caps Lock acts as Esc", "note": "Karabiner rule" }
      ]
    }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique identifier for the sheet |
| `name` | yes | Shown in the sidebar and the overlay |
| `symbol` | yes | An SF Symbol name for the sidebar icon |
| `show` | no | Where the overlay shows the sheet (see below). Leave it out to show the sheet only in the main window |
| `sections` | yes | Titled groups of entries |
| `entries[].action` | yes | Unique within the sheet. Built-in sheets use it to match live bindings |
| `entries[].keys` | yes | One string per keycap, in the order pressed |
| `entries[].description` | yes | What the binding does |
| `entries[].note` | no | Shown under the description |
| `prefix` | no | A prefix keycap, written as `{prefix}` in `keys` |
| `layer` | no | For terminal sheets: nesting depth. A higher number appears first |

`show` takes one of three forms:

```json
"show": "everywhere"
"show": { "apps": ["com.apple.finder", "com.apple.Safari"] }
"show": { "terminalTitle": "\\bhtop\\b" }
```

`apps` takes bundle IDs, plus `"@terminals"` for any supported terminal. `terminalTitle` is a case-insensitive regular expression matched against the terminal's window title.

A sheet that fails to load is listed with its error under Settings → Files.

### The sheet editor

- **New sheet:** click **+** above the sidebar, or press ⌘N.
- **Edit a sheet:** double-click it in the sidebar, or right-click it and choose **Edit…**.

To record keys, click the record button next to an entry's keys, press the keys, then click it again. Each press becomes one keycap, so a sequence such as ⌃B then % becomes two. You can also type keycaps separated by spaces, with quotes around a keycap that contains spaces, such as `":e {file}"`.

Saving writes JSON to `~/.config/cheetsheet/sheets/`. Each sheet goes back to its own file, symlinks are kept, and keys are sorted so the files diff cleanly in a dotfiles repository. Editing a built-in sheet saves your own copy. **Revert to Built-in** moves that copy to the Bin.

### Known limitations

- Live bindings are read from the local Mac only, not from remote machines over SSH.
- Menu shortcuts do not show struck-through defaults. macOS menus only expose the shortcut currently in effect.
- Vim mappings are compared by key against the Vim sheet's normal-mode entries only. Neovim mappings are not read yet.
- Downloadable sheets from a shared index are planned but not built yet.

## License

No license is specified.
