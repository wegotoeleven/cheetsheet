import AppKit
import SwiftUI

/// The modifier key you hold to bring up the overlay.
/// Saved in config.json by its raw value, e.g. "command".
nonisolated enum TriggerKey: String, CaseIterable, Identifiable, Codable {
    case command, option, control, shift

    var id: Self { self }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .command: .command
        case .option: .option
        case .control: .control
        case .shift: .shift
        }
    }

    var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        }
    }

    var name: String {
        switch self {
        case .command: "Command"
        case .option: "Option"
        case .control: "Control"
        case .shift: "Shift"
        }
    }
}

/// Shortcuts for reading settings outside SwiftUI views. The values live in config.json.
enum AppSettings {
    private static var config: ConfigFile { SettingsStore.shared.config }

    static var trigger: TriggerKey { config.trigger }
    static var holdDelay: Double { config.holdDelay }
    static var showMenuBarIcon: Bool { config.showMenuBarIcon }
    static var hideHostMenus: Bool { config.hideTerminalShortcuts }

    /// How many of Cheetsheet's windows (main, Settings) are open right now.
    private static var openWindows = 0

    /// Called by each window as it opens and closes.
    static func windowOpened() { openWindows += 1; applyDockIconPolicy() }
    static func windowClosed() { openWindows = max(0, openWindows - 1); applyDockIconPolicy() }

    /// Shows or hides the Dock icon. "Accessory" apps have no Dock icon or app menu bar,
    /// but keep their menu bar extra, overlay and any open windows.
    static func applyDockIconPolicy() {
        // With the menu bar icon gone, the Dock icon is the only way back in, so it stays.
        let showDock = openWindows > 0 || !showMenuBarIcon
        let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Becoming a regular app can leave our window behind others; bring it forward.
        // (Not when hiding: that would steal focus from the app you're switching back to.)
        if showDock { DispatchQueue.main.async { NSApp.activate() } }
    }

}

struct SettingsView: View {
    // @Bindable lets controls bind straight to the store's settings; changes save to config.json.
    @Bindable private var settings = SettingsStore.shared
    @Environment(SheetStore.self) private var sheets
    @State private var configStatuses: [TerminalConfig.Status] = []
    @State private var pendingAppend: TerminalConfig.Status?
    @State private var appendError: String?

    var body: some View {
        Form {
            Section {
                LaunchAtLoginToggle()
                Toggle("Show in menu bar", isOn: $settings.config.showMenuBarIcon)
            } header: {
                Text("App")
            } footer: {
                Text("The Dock icon shows while a Cheetsheet window is open. Without the menu bar icon, it stays in the Dock so you can always get back in. The overlay works either way.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Hold to show", selection: $settings.config.trigger) {
                    ForEach(TriggerKey.allCases) { key in
                        Text("\(key.symbol)  \(key.name)").tag(key)
                    }
                }
                LabeledContent("Hold for") {
                    HStack {
                        Slider(value: $settings.config.holdDelay, in: 0.2...2.0, step: 0.1)
                        Text(settings.config.holdDelay, format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                        Text("s").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Overlay")
            } footer: {
                Text("Hold the key on its own to show the front app's shortcuts. Using it with another key cancels.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(ConfigFolder.tildePath(ConfigFolder.url)).textSelection(.enabled)
                        Button("Show in Finder") { NSWorkspace.shared.open(ConfigFolder.url) }
                    }
                }
                if let error = settings.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                ForEach(sheets.loadErrors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                Text("Files")
            } footer: {
                Text("Settings are saved in config.json. Put your own cheatsheets in the sheets folder; a sheet with the same id as a built-in one replaces it. Both can live in your dotfiles, and edits made elsewhere are picked up straight away.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide the terminal's own shortcuts when tmux, herdr or vim is detected", isOn: $settings.config.hideTerminalShortcuts)
                ForEach(configStatuses, id: \.config.id) { status in
                    configRow(status)
                }
                DisclosureGroup("Lines for other machines") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("~/.tmux.conf")
                        snippet("set -g set-titles on\nset -g set-titles-string \"#T — tmux\"")
                        Text("~/.config/herdr/config.toml, in [ui]").padding(.top, 4)
                        snippet("window_title = \"{workspace}: {terminal_title} — herdr\"")
                        Text("~/.vimrc or init.vim").padding(.top, 4)
                        snippet("set title")
                        Text("init.lua").padding(.top, 4)
                        snippet("vim.opt.title = true")
                    }
                    .padding(.top, 6)
                }
            } header: {
                Text("Terminals")
            } footer: {
                Text("Cheetsheet spots tmux, herdr and vim from the terminal window's title, so it also works over SSH. Machines you SSH into need these lines too. If your configs live in a dotfiles repo, commit the change there. After adding, restart vim, run tmux source-file ~/.tmux.conf and run herdr server reload-config.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            refreshConfigs()
            AppSettings.windowOpened()
        }
        .onDisappear { AppSettings.windowClosed() }
        .confirmationDialog(
            "Add lines to \(pendingAppend.flatMap(\.resolved).map(ConfigFolder.tildePath) ?? "")?",
            isPresented: Binding(get: { pendingAppend != nil }, set: { if !$0 { pendingAppend = nil } }),
            presenting: pendingAppend
        ) { status in
            Button("Add lines") { append(status) }
        } message: { status in
            Text("These lines will be added to the file:\n\(status.linesToAdd ?? "")")
        }
        .alert("Couldn't update the file", isPresented: Binding(get: { appendError != nil }, set: { if !$0 { appendError = nil } })) {
            Button("OK") {}
        } message: {
            Text(appendError ?? "")
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func configRow(_ status: TerminalConfig.Status) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.config.name)
                Text(pathDescription(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if status.isConfigured {
                Label("Set up", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if status.linesToAdd != nil {
                Button("Add lines…") { pendingAppend = status }
            } else if status.url != nil {
                Text("Edit by hand").foregroundStyle(.secondary)
            }
        }
    }

    private func pathDescription(_ status: TerminalConfig.Status) -> String {
        guard let url = status.url, let resolved = status.resolved else { return "No config file found" }
        let shown = ConfigFolder.tildePath(url)
        return resolved.standardizedFileURL == url.standardizedFileURL ? shown : "\(shown) → \(ConfigFolder.tildePath(resolved))"
    }

    private func refreshConfigs() {
        configStatuses = TerminalConfig.all.map { $0.status() }
    }

    private func append(_ status: TerminalConfig.Status) {
        do {
            try TerminalConfig.append(status)
        } catch {
            appendError = error.localizedDescription
        }
        refreshConfigs()
    }

    /// A selectable, monospaced block of config to copy.
    private func snippet(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
