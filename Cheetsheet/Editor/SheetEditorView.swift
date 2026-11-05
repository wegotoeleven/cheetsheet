import SwiftUI
import UniformTypeIdentifiers

/// Makes or changes a sheet, then saves it as JSON in ~/.config/cheetsheet/sheets.
struct SheetEditorView: View {
    @State var draft: SheetDraft
    /// Called with the saved sheet's id, or nil if it was deleted.
    let onFinish: (String?) -> Void
    @Environment(SheetStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    @State private var confirmingDelete = false

    private var isBuiltIn: Bool { draft.originalID.map(store.builtInIDs.contains) ?? false }
    private var hasUserFile: Bool { draft.originalID.map { store.userSheetFiles[$0] != nil } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isBuiltIn && !hasUserFile {
                    Section {
                        Label("This sheet comes with Cheetsheet. Saving makes your own copy in \(ConfigFolder.tildePath(ConfigFolder.sheetsFolder)), which replaces it. Delete your copy later to go back.",
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Window keys"))
                    SymbolField(symbol: $draft.symbol)
                }
                ShowSection(draft: $draft)
                ForEach($draft.sections) { $section in
                    SectionEditor(section: $section,
                                  canMoveUp: section.id != draft.sections.first?.id,
                                  canMoveDown: section.id != draft.sections.last?.id,
                                  move: { offset in moveSection(section.id, by: offset) },
                                  delete: { draft.sections.removeAll { $0.id == section.id } })
                }
                Section {
                    Button("Add Section", systemImage: "plus") {
                        draft.sections.append(.init(title: "", entries: [.init(keysText: "", description: "", note: "")]))
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 560, idealHeight: 720)
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete) {
            Button(deleteButtonLabel, role: .destructive, action: delete)
        } message: {
            Text("The file is moved to the Bin, so you can get it back.")
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if hasUserFile {
                Button(deleteButtonLabel, role: .destructive) { confirmingDelete = true }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(saveError.map { [$0] } ?? draft.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(saveError == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.problems.isEmpty)
        }
    }

    private var deleteButtonLabel: String { isBuiltIn ? "Revert to Built-in" : "Delete Sheet" }
    private var deleteTitle: String {
        isBuiltIn ? "Remove your copy and go back to the built-in “\(draft.name)” sheet?" : "Delete “\(draft.name)”?"
    }

    private func moveSection(_ id: UUID, by offset: Int) {
        guard let index = draft.sections.firstIndex(where: { $0.id == id }),
              draft.sections.indices.contains(index + offset) else { return }
        draft.sections.swapAt(index, index + offset)
    }

    private func save() {
        KeyRecorder.shared.stop()
        let id = draft.originalID ?? store.unusedID(for: draft.name)
        do {
            try store.save(draft.makeSheet(id: id))
            onFinish(id)
            dismiss()
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func delete() {
        guard let id = draft.originalID else { return }
        do {
            try store.deleteUserSheet(id: id)
            onFinish(isBuiltIn ? id : nil)
            dismiss()
        } catch {
            saveError = "Couldn't delete: \(error.localizedDescription)"
        }
    }
}

/// The SF Symbol name with a preview, and a warning when there's no such symbol.
private struct SymbolField: View {
    @Binding var symbol: String
    private var exists: Bool { NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil }

    var body: some View {
        LabeledContent("Icon") {
            HStack {
                Image(systemName: exists ? symbol : "questionmark.square.dashed")
                    .frame(width: 20)
                    .foregroundStyle(exists ? .primary : .secondary)
                TextField("Icon", text: $symbol, prompt: Text("SF Symbol name"))
                    .labelsHidden()
                Link("Browse…", destination: URL(string: "https://developer.apple.com/sf-symbols/")!)
                    .font(.caption)
            }
        }
        if !exists && !symbol.isEmpty {
            Text("No SF Symbol is called “\(symbol)”. The sidebar shows no icon for it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Where the overlay shows the sheet, and the settings for that choice.
private struct ShowSection: View {
    @Binding var draft: SheetDraft
    @State private var testTitle = ""

    var body: some View {
        Section("Shows up") {
            Picker("In the overlay", selection: $draft.showMode) {
                ForEach(SheetDraft.ShowMode.allCases) { Text($0.label).tag($0) }
            }
            switch draft.showMode {
            case .mainWindow:
                hint("Only in this window's sidebar, never in the overlay. Good for reference sheets.")
            case .everywhere:
                hint("In the overlay whatever app you're in.")
            case .apps:
                AppList(apps: $draft.apps)
            case .terminal:
                terminalFields
            }
        }
    }

    @ViewBuilder private var terminalFields: some View {
        TextField("Window title pattern", text: $draft.titlePattern, prompt: Text(#"e.g. \bhtop\b"#))
            .font(.system(.body, design: .monospaced))
        hint(#"A regular expression matched against the terminal window's title, which shows the program that's running. Put \b either side of a program's name so “vim” doesn't match “environment”."#)
        TextField("Test with a title", text: $testTitle, prompt: Text("Paste a window title"))
        if !testTitle.isEmpty, !draft.titlePattern.isEmpty {
            if !SheetDraft.isValidPattern(draft.titlePattern) {
                Label("Not a valid pattern", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            } else if testTitle.range(of: draft.titlePattern, options: [.regularExpression, .caseInsensitive]) != nil {
                Label("Matches: the sheet would show", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Doesn't match", systemImage: "xmark.circle").foregroundStyle(.secondary)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// The chosen apps, with a menu to add one that's running, any terminal, or any app on disk.
private struct AppList: View {
    @Binding var apps: [String]

    var body: some View {
        ForEach(apps, id: \.self) { bundleID in
            HStack {
                AppLabel(bundleID: bundleID)
                Spacer()
                Button("Remove", systemImage: "minus.circle") { apps.removeAll { $0 == bundleID } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        Menu("Add App", systemImage: "plus") {
            Button("Any Terminal") { add("@terminals") }
            Divider()
            ForEach(runningApps, id: \.bundleID) { app in
                Button(app.name) { add(app.bundleID) }
            }
            Divider()
            Button("Choose…", action: choose)
        }
        .fixedSize()
    }

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .filter { !apps.contains($0.bundleID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func add(_ bundleID: String) {
        if !apps.contains(bundleID) { apps.append(bundleID) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        add(bundleID)
    }
}

/// An app's icon and name from its bundle ID, or the ID itself if it isn't installed.
private struct AppLabel: View {
    let bundleID: String

    var body: some View {
        if bundleID == "@terminals" {
            Label("Any terminal", systemImage: "terminal")
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Label {
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
            }
        } else {
            Label(bundleID, systemImage: "app.dashed")
        }
    }
}

/// One section: its title, its entries, and buttons to add, move and delete.
private struct SectionEditor: View {
    @Binding var section: SheetDraft.SectionDraft
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        Section {
            ForEach($section.entries) { $entry in
                EntryRow(entry: $entry,
                         canMoveUp: entry.id != section.entries.first?.id,
                         canMoveDown: entry.id != section.entries.last?.id,
                         move: { offset in moveEntry(entry.id, by: offset) },
                         delete: { section.entries.removeAll { $0.id == entry.id } })
            }
            Button("Add Entry", systemImage: "plus") {
                section.entries.append(.init(keysText: "", description: "", note: ""))
            }
            .buttonStyle(.borderless)
        } header: {
            HStack {
                TextField("Section title", text: $section.title, prompt: Text("Section title"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.headline)
                Menu {
                    Button("Move Section Up", systemImage: "arrow.up") { move(-1) }.disabled(!canMoveUp)
                    Button("Move Section Down", systemImage: "arrow.down") { move(1) }.disabled(!canMoveDown)
                    Divider()
                    Button("Delete Section", systemImage: "trash", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func moveEntry(_ id: UUID, by offset: Int) {
        guard let index = section.entries.firstIndex(where: { $0.id == id }),
              section.entries.indices.contains(index + offset) else { return }
        section.entries.swapAt(index, index + offset)
    }
}

/// Keys, description and note on one line, with a preview of the keycaps.
private struct EntryRow: View {
    @Binding var entry: SheetDraft.EntryDraft
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                KeysField(text: $entry.keysText)
                HStack(spacing: 3) {
                    ForEach(Array(entry.keys.enumerated()), id: \.offset) { _, key in
                        KeycapView(label: key, compact: true)
                    }
                }
                .frame(minHeight: 18)
            }
            .frame(width: 200)
            TextField("Description", text: $entry.description, prompt: Text("What it does"))
                .labelsHidden()
            TextField("Note", text: $entry.note, prompt: Text("Note (optional)"))
                .labelsHidden()
                .frame(width: 170)
            Menu {
                Button("Move Up", systemImage: "arrow.up") { move(-1) }.disabled(!canMoveUp)
                Button("Move Down", systemImage: "arrow.down") { move(1) }.disabled(!canMoveDown)
                Divider()
                Button("Delete Entry", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
