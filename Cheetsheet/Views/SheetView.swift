import SwiftUI

/// Shows one cheatsheet: section chips, a searchable list of bindings.
struct SheetView: View {
    let sheet: Cheatsheet
    @Environment(SheetStore.self) private var store
    @State private var query = ""
    @State private var sectionFilter: String?

    private var live: LiveBindings? { store.live[sheet.id] }
    private var groups: [MenuGroup] { sheet.shortcutGroups(live: live) }

    /// Sections after applying the chip filter and search text.
    private var visibleSections: [MenuGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return groups
            .filter { sectionFilter == nil || $0.title == sectionFilter }
            .compactMap { group in  // compactMap = map, then drop the nils
                guard !q.isEmpty else { return group }
                let hits = group.items.filter { $0.matches(q) }
                return hits.isEmpty ? nil : MenuGroup(id: group.id, title: group.title, items: hits)
            }
    }

    /// "Prefix ⌃a · from running tmux server"
    private var subtitle: String {
        let prefix = (live?.prefix ?? sheet.prefix).map { "Prefix \($0)" }
        return [prefix, live.map { "Your bindings from \($0.source)" }].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionChips(titles: groups.map(\.title), selection: $sectionFilter)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                MasonryLayout {
                    ForEach(visibleSections) { group in
                        ShortcutCard(title: group.title) {
                            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                ShortcutRow(title: item.title, note: item.note, keys: item.keys, replaced: item.replaced, alsoWorks: item.alsoWorks)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .overlay {
                if visibleSections.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle(sheet.name)
        .navigationSubtitle(subtitle)
        .task { await store.refreshLiveBindings() }
        .searchable(text: $query, placement: .toolbar, prompt: "Search shortcuts")
    }
}

private struct SectionChips: View {
    let titles: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip("All", value: nil)
                ForEach(titles, id: \.self) { chip($0, value: $0) }
            }
        }
    }

    private func chip(_ title: String, value: String?) -> some View {
        let isSelected = selection == value
        return Button(title) { selection = value }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(isSelected ? Color.primary.opacity(0.1) : .clear, in: Capsule())
            .contentShape(Capsule())
    }
}
