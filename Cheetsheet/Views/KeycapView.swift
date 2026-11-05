import SwiftUI

/// A single key drawn as a small raised keycap.
struct KeycapView: View {
    let label: String
    var compact = false
    /// A default the user has changed: dimmed and struck through.
    var struck = false
    /// A default that still works but isn't the user's key: dimmed only.
    var dimmed = false

    var body: some View {
        Text(label)
            .font(.system(compact ? .caption : .callout, design: .monospaced))
            .strikethrough(struck)
            .foregroundStyle(struck || dimmed ? .secondary : .primary)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .frame(minWidth: compact ? 20 : 24)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.separator)
            }
            .opacity(struck || dimmed ? 0.55 : 1)
    }
}

#Preview {
    HStack { KeycapView(label: "⌃b"); KeycapView(label: "%"); KeycapView(label: "gg", compact: true) }
        .padding()
}
