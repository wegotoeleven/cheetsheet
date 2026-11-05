import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Turns key presses into keycaps for the sheet editor.
///
/// While recording, every key pressed in Cheetsheet goes to the recorder instead of the
/// app, so ⌘W is recorded rather than closing the window. Only one field records at a time,
/// and the overlay stays away while it does.
final class KeyRecorder {
    static let shared = KeyRecorder()
    private(set) var isRecording = false
    private var monitor: Any?
    private var onStop: (() -> Void)?

    /// Calls `onKey` with each key press's keycaps until `stop()`.
    func start(onKey: @escaping ([String]) -> Void, onStop: @escaping () -> Void) {
        stop()
        isRecording = true
        self.onStop = onStop
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKey(Self.keycaps(for: event))
            return nil  // swallow it, so it doesn't also type or run a menu command
        }
    }

    func stop() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        let onStop = onStop
        self.onStop = nil
        onStop?()
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "esc",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "home", kVK_End: "end", kVK_PageUp: "pgup", kVK_PageDown: "pgdn",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// One key press as keycaps, in the order macOS menus use: ⌃ ⌥ ⇧ ⌘, then the key.
    /// Without ⌃, ⌥ or ⌘ the character is kept as typed, so ⇧G is "G" and ⇧4 is "$",
    /// which is how vim-style sheets write them.
    static func keycaps(for event: NSEvent) -> [String] {
        let flags = event.modifierFlags
        let hasCommandLike = !flags.isDisjoint(with: [.control, .option, .command])
        var key = specialKeys[Int(event.keyCode)]
            ?? event.charactersIgnoringModifiers.map { $0 } ?? "?"
        if specialKeys[Int(event.keyCode)] == nil, hasCommandLike { key = key.uppercased() }

        var caps: [String] = []
        if flags.contains(.control) { caps.append("⌃") }
        if flags.contains(.option) { caps.append("⌥") }
        // Shift goes in its own keycap when it isn't already in the character (⇧⌘D, ⇧↩).
        if flags.contains(.shift), hasCommandLike || specialKeys[Int(event.keyCode)] != nil { caps.append("⇧") }
        if flags.contains(.command) { caps.append("⌘") }
        return caps + [key]
    }
}

/// A keys field with a record button: type keycaps separated by spaces (quote one that
/// contains spaces, like `":e {file}"`), or press Record
/// and press the keys themselves. Each press becomes one keycap and is added to the end,
/// so sequences like ⌃B then % work.
struct KeysField: View {
    @Binding var text: String
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 4) {
            TextField("Keys", text: $text, prompt: Text(isRecording ? "Press keys…" : "Keys"))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .disabled(isRecording)
            Button {
                isRecording ? KeyRecorder.shared.stop() : start()
            } label: {
                Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(isRecording ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isRecording ? "Stop recording" : "Record keys: press them, then click again to stop")
        }
        .help(#"Keycaps separated by spaces. Put one that contains spaces in quotes: ":e {file}""#)
        .onDisappear { if isRecording { KeyRecorder.shared.stop() } }
    }

    private func start() {
        text = ""
        isRecording = true
        KeyRecorder.shared.start(
            onKey: { caps in
                // One keycap per press ("⌃⌥⌘H"), so a sequence reads as separate presses: "⌃B %".
                let pressed = caps.joined()
                text = text.isEmpty ? pressed : text + " " + pressed
            },
            onStop: { isRecording = false })
    }
}
