import SwiftUI

/// What's selected in the sidebar. An enum with associated values is like a
/// tagged union: either "current app" or "a sheet with this id".
enum SidebarItem: Hashable {
    case currentApp
    case sheet(String)
}

struct ContentView: View {
    @Environment(SheetStore.self) private var store
    @State private var selection: SidebarItem?
    /// The sheet open in the editor, if any.
    @State private var editing: SheetDraft?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Live") {
                    Label("Current app", systemImage: "macwindow")
                        .tag(SidebarItem.currentApp)
                }
                Section("Sheets") {
                    ForEach(store.sheets) { sheet in
                        HStack {
                            Label(sheet.name, systemImage: sheet.symbol)
                            Spacer()
                            if let label = showLabel(for: sheet) {
                                Text(label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(SidebarItem.sheet(sheet.id))
                    }
                }
            }
            // Double-clicking a sheet (the "primary action") opens it in the editor;
            // right-clicking offers the same.
            .contextMenu(forSelectionType: SidebarItem.self) { items in
                if let sheet = editableSheet(items) {
                    Button("Edit…") { editing = SheetDraft(sheet) }
                }
            } primaryAction: { items in
                if let sheet = editableSheet(items) { editing = SheetDraft(sheet) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .toolbar {
                Button("New Sheet", systemImage: "plus") { editing = SheetDraft() }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("Make a new sheet (⌘N)")
            }
        } detail: {
            detail
        }
        .sheet(item: $editing) { draft in
            SheetEditorView(draft: draft) { savedID in
                // Show what was just saved; after a delete, fall back to the first sheet.
                if let savedID {
                    selection = .sheet(savedID)
                } else {
                    selection = store.sheets.first.map { .sheet($0.id) }
                }
            }
            .environment(store)
        }
        .onAppear {
            if selection == nil, let first = store.sheets.first {
                selection = .sheet(first.id)
            }
        }
    }

    /// The sheet a sidebar click was on; nil for "Current app", which can't be edited.
    private func editableSheet(_ items: Set<SidebarItem>) -> Cheatsheet? {
        guard items.count == 1, case .sheet(let id) = items.first else { return nil }
        return store.sheet(id: id)
    }

    /// When the overlay shows a sheet by itself: "Everywhere", an app's name, or "In terminals".
    private func showLabel(for sheet: Cheatsheet) -> String? {
        switch sheet.show {
        case .everywhere: "Everywhere"
        case .terminalTitle: "In terminals"
        case .apps(let ids): ids.map(appName).joined(separator: ", ")
        case nil: nil
        }
    }

    private func appName(_ bundleID: String) -> String {
        if bundleID == "@terminals" { return "Terminals" }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .currentApp:
            CurrentAppView()
        case .sheet(let id):
            if let sheet = store.sheet(id: id) {
                // .id() resets the view's search and filter when switching sheets.
                SheetView(sheet: sheet).id(sheet.id)
            } else {
                ContentUnavailableView("Cheatsheet not found", systemImage: "questionmark.folder")
            }
        case nil:
            ContentUnavailableView("Choose a cheatsheet", systemImage: "list.bullet.rectangle")
        }
    }
}
