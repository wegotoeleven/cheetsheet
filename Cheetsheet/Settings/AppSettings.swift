import AppKit
import SwiftUI

/// The modifier key you hold to bring up the overlay.
/// `String` raw values let it be saved in UserDefaults via @AppStorage.
enum TriggerKey: String, CaseIterable, Identifiable {
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

/// Reads settings outside SwiftUI views. Keys must match the @AppStorage keys below.
enum AppSettings {
    static let triggerKeyName = "triggerKey"
    static let holdDelayName = "holdDelay"
    static let defaultHoldDelay = 0.8
    static let showDockIconName = "showDockIcon"
    static let showMenuBarIconName = "showMenuBarIcon"
    static let hideHostMenusName = "hideHostMenus"

    /// Hide the terminal's own menus when tmux or vim is detected inside it.
    static var hideHostMenus: Bool { UserDefaults.standard.bool(forKey: hideHostMenusName) }

    static var showDockIcon: Bool {
        UserDefaults.standard.object(forKey: showDockIconName) as? Bool ?? true
    }

    /// Shows or hides the Dock icon. "Accessory" apps have no Dock icon or app menu bar.
    static func applyDockIconPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        // Switching policy can push our windows behind other apps; bring them back.
        DispatchQueue.main.async { NSApp.activate() }
    }

    static var trigger: TriggerKey {
        UserDefaults.standard.string(forKey: triggerKeyName).flatMap(TriggerKey.init(rawValue:)) ?? .command
    }

    static var holdDelay: Double {
        let value = UserDefaults.standard.double(forKey: holdDelayName)  // 0 when never set
        return value > 0 ? value : defaultHoldDelay
    }
}

struct SettingsView: View {
    // @AppStorage reads and writes UserDefaults and redraws the view on change.
    @AppStorage(AppSettings.triggerKeyName) private var trigger: TriggerKey = .command
    @AppStorage(AppSettings.holdDelayName) private var holdDelay: Double = AppSettings.defaultHoldDelay
    @AppStorage(AppSettings.showDockIconName) private var showDockIcon = true
    @AppStorage(AppSettings.showMenuBarIconName) private var showMenuBarIcon = true
    @AppStorage(AppSettings.hideHostMenusName) private var hideHostMenus = false
    @State private var configStatuses: [TerminalConfig.Status] = []
    @State private var pendingAppend: TerminalConfig.Status?
    @State private var appendError: String?

    var body: some View {
        Form {
            Section {
                // Each toggle is locked on while the other is off, so Cheetsheet stays reachable.
                Toggle("Show in Dock", isOn: $showDockIcon)
                    .disabled(showDockIcon && !showMenuBarIcon)
                Toggle("Show in menu bar", isOn: $showMenuBarIcon)
                    .disabled(showMenuBarIcon && !showDockIcon)
            } header: {
                Text("App")
            } footer: {
                Text("At least one has to stay on so you can open Cheetsheet.")
                    .foregroundStyle(.secondary)
            }
            .onChange(of: showDockIcon) { AppSettings.applyDockIconPolicy() }

            Section {
                Picker("Hold to show", selection: $trigger) {
                    ForEach(TriggerKey.allCases) { key in
                        Text("\(key.symbol)  \(key.name)").tag(key)
                    }
                }
                LabeledContent("Hold for") {
                    HStack {
                        Slider(value: $holdDelay, in: 0.2...2.0, step: 0.1)
                        Text(holdDelay, format: .number.precision(.fractionLength(1)))
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
                Toggle("Hide the terminal's own menus when tmux or vim is detected", isOn: $hideHostMenus)
                ForEach(configStatuses, id: \.config.id) { status in
                    configRow(status)
                }
                DisclosureGroup("Lines for other machines") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("~/.tmux.conf")
                        snippet("set -g set-titles on\nset -g set-titles-string \"#T — tmux\"")
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
                Text("Cheetsheet spots tmux and vim from the terminal window's title, so it also works over SSH. Machines you SSH into need these lines too. If your configs live in a dotfiles repo, commit the change there. After adding, restart vim and run tmux source-file ~/.tmux.conf.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refreshConfigs)
        .confirmationDialog(
            "Add lines to \(pendingAppend.flatMap(\.resolved).map(tildePath) ?? "")?",
            isPresented: Binding(get: { pendingAppend != nil }, set: { if !$0 { pendingAppend = nil } }),
            presenting: pendingAppend
        ) { status in
            Button("Add lines") { append(status) }
        } message: { status in
            Text("These lines will be added to the end of the file:\n\(status.linesToAdd)")
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
            } else if status.url != nil {
                Button("Add lines…") { pendingAppend = status }
            }
        }
    }

    private func pathDescription(_ status: TerminalConfig.Status) -> String {
        guard let url = status.url, let resolved = status.resolved else { return "No config file found" }
        let shown = tildePath(url)
        return resolved.standardizedFileURL == url.standardizedFileURL ? shown : "\(shown) → \(tildePath(resolved))"
    }

    private func tildePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
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
