import SwiftUI

/// One line of a cheatsheet: description on the left, keycaps on the right.
/// Shared by sheets, the current-app view and the overlay.
struct ShortcutRow: View {
    let title: String
    var note: String? = nil
    let keys: [String]
    /// Default keys the user has changed, shown struck through before the new ones.
    var replaced: [String]? = nil
    /// Default keys that still work, shown greyed after the user's own.
    var alsoWorks: [String]? = nil
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(compact ? 1 : 2)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                if let replaced {
                    ForEach(Array(replaced.enumerated()), id: \.offset) { _, key in
                        KeycapView(label: key, compact: compact, struck: true)
                    }
                    if !keys.isEmpty {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 2)
                    }
                }
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    KeycapView(label: key, compact: compact)
                }
                if let alsoWorks {
                    HStack(spacing: 3) {
                        ForEach(Array(alsoWorks.enumerated()), id: \.offset) { _, key in
                            KeycapView(label: key, compact: compact, dimmed: true)
                        }
                    }
                    .padding(.leading, 6)
                }
            }
            .fixedSize()
            .help(helpText)
        }
        .font(compact ? .callout : .body)
    }
}

extension ShortcutRow {
    private var helpText: String {
        if let replaced { return "Default \(replaced.joined(separator: " ")) no longer works" }
        if let alsoWorks { return "Default \(alsoWorks.joined(separator: " ")) still works too" }
        return ""
    }
}

/// A titled card of rows, used for each section of a sheet or menu.
struct ShortcutCard<Rows: View>: View {
    let title: String
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            // Group(subviews:) lets us put a divider between whatever rows were passed in.
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: rows) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.leading, 12) }
                        row.padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

/// Lays children out in as many columns as fit, dropping each child into the
/// shortest column (a "masonry" layout), so cards of different heights pack tightly.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 320
    var spacing: CGFloat = 20

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let count = max(1, Int((width + spacing) / (minColumnWidth + spacing)))
        let columnWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        var heights = Array(repeating: CGFloat.zero, count: count)
        var frames: [CGRect] = []
        for subview in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column],
                                 width: columnWidth, height: height))
            heights[column] += height + spacing
        }
        return (frames, max(0, (heights.max() ?? 0) - spacing))
    }
}
