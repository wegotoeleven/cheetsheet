import SwiftUI

/// One block of shortcuts in the overlay: a matched sheet (vim, tmux) or the app's menus.
struct OverlayLayer {
    let name: String
    let groups: [MenuGroup]
}

/// Everything the overlay needs to draw itself, as plain values.
struct OverlayContent {
    enum State {
        case loading
        case needsPermission
        case layers([OverlayLayer])
    }

    /// Outermost first, e.g. ["Ghostty", "tmux", "Vim"].
    var breadcrumb: [String]
    var appIcon: NSImage?
    var state: State
    /// Small explanatory line under the header, e.g. why nothing was detected.
    var hint: String? = nil
    var triggerSymbol: String
    var maxRowsPerColumn: Int
    /// Widest the columns can be before they scroll sideways.
    var maxContentWidth: CGFloat

    static let placeholder = OverlayContent(breadcrumb: [], appIcon: nil, state: .loading, triggerSymbol: "⌘",
                                            maxRowsPerColumn: 20, maxContentWidth: 1200)
}

private let columnWidth: CGFloat = 270
private let columnSpacing: CGFloat = 20
private let layerSpacing: CGFloat = 36

struct OverlayView: View {
    let content: OverlayContent

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let hint = content.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, -8)
            }
            switch content.state {
            case .loading:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 60)
            case .needsPermission:
                Text("Allow Cheetsheet in System Settings → Privacy & Security → Accessibility to see this app's shortcuts.")
                    .foregroundStyle(.secondary)
                    .frame(width: 380, alignment: .leading)
            case .layers(let layers):
                let shown = layers.filter { !$0.groups.isEmpty }
                if shown.isEmpty {
                    Text("No keyboard shortcuts found in this app's menus.")
                        .foregroundStyle(.secondary)
                } else {
                    layersView(shown)
                    legend(for: shown)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = content.appIcon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            breadcrumbText.font(.title3)
            Spacer(minLength: 24)
            Text("Release \(content.triggerSymbol) to close").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "Ghostty › tmux › Vim", with the innermost part emphasised.
    private var breadcrumbText: Text {
        content.breadcrumb.enumerated().reduce(Text("")) { text, element in
            let (index, part) = element
            let isLast = index == content.breadcrumb.count - 1
            let piece = Text(part)
                .fontWeight(isLast ? .semibold : .regular)
                .foregroundStyle(isLast ? .primary : .secondary)
            let separator = Text("  ›  ").foregroundStyle(.tertiary)
            return index == 0 ? piece : Text("\(text)\(separator)\(piece)")
        }
    }

    /// All layers side by side, scrolling sideways only when wider than the screen allows.
    @ViewBuilder
    private func layersView(_ layers: [OverlayLayer]) -> some View {
        let laidOut = layers.map { layoutColumns($0.groups) }
        let width = laidOut.reduce(0) { total, columns in
            total + CGFloat(columns.count) * columnWidth + CGFloat(columns.count - 1) * columnSpacing
        } + CGFloat(layers.count - 1) * layerSpacing

        let stack = HStack(alignment: .top, spacing: layerSpacing) {
            ForEach(layers.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 10) {
                    // Only label layers when there's more than one; a lone app needs no heading.
                    if layers.count > 1 {
                        Text(layers[index].name).font(.headline)
                    }
                    columnStack(laidOut[index])
                }
            }
        }

        if width > content.maxContentWidth {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) { stack }
                    .frame(width: content.maxContentWidth)
                Text("Scroll for more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            stack
        }
    }

    /// Explains greyed and struck-out keys, only when some are on screen.
    @ViewBuilder
    private func legend(for layers: [OverlayLayer]) -> some View {
        let items = layers.flatMap(\.groups).flatMap(\.items)
        let hasGreyed = items.contains { $0.alsoWorks != nil }
        let hasStruck = items.contains { $0.replaced != nil }
        if hasGreyed || hasStruck {
            HStack(spacing: 16) {
                if hasGreyed {
                    HStack(spacing: 6) {
                        KeycapView(label: "a", compact: true, dimmed: true)
                        Text("Default that still works, but you've added your own key")
                    }
                }
                if hasStruck {
                    HStack(spacing: 6) {
                        KeycapView(label: "a", compact: true, struck: true)
                        Text("Default you've removed or rebound")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func columnStack(_ laidOut: [[MenuGroup]]) -> some View {
        HStack(alignment: .top, spacing: columnSpacing) {
            ForEach(Array(laidOut.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, group in
                        ShortcutCard(title: group.title) {
                            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                ShortcutRow(title: item.title, note: item.note, keys: item.keys, replaced: item.replaced,
                                            alsoWorks: item.alsoWorks, compact: true)
                            }
                        }
                    }
                }
                .frame(width: columnWidth)
            }
        }
    }

    /// Fills columns top to bottom in order, starting a new column when the
    /// next group won't fit. Groups longer than a whole column are split.
    private func layoutColumns(_ groups: [MenuGroup]) -> [[MenuGroup]] {
        let maxRows = content.maxRowsPerColumn
        var chunks: [MenuGroup] = []
        for group in groups {
            stride(from: 0, to: group.items.count, by: maxRows).forEach { start in
                let slice = Array(group.items[start..<min(start + maxRows, group.items.count)])
                chunks.append(MenuGroup(id: group.id, title: start == 0 ? group.title : "\(group.title) (cont.)", items: slice))
            }
        }

        var columns: [[MenuGroup]] = [[]]
        var rows = 0
        for chunk in chunks {
            // One row per item, plus roughly half a row for each note, plus 2 for the title and spacing.
            let needed = chunk.items.count + (chunk.items.filter { $0.note != nil }.count + 1) / 2 + 2
            if rows > 0, rows + needed > maxRows {
                columns.append([])
                rows = 0
            }
            columns[columns.count - 1].append(chunk)
            rows += needed
        }
        return columns
    }
}
