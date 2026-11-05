import ServiceManagement
import SwiftUI

/// Opens Cheetsheet when you log in, using macOS's own login items.
///
/// Unlike other settings this isn't kept in config.json: macOS already stores it (it's
/// listed in System Settings → General → Login Items), and keeping a second copy would
/// let the two disagree, e.g. after you turn it off there.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    /// True when macOS wants you to allow it in System Settings first.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// The Settings toggle. It re-reads the status whenever Settings opens, so a change made
/// in System Settings shows up here.
struct LaunchAtLoginToggle: View {
    @State private var isOn = LaunchAtLogin.isEnabled
    @State private var needsApproval = LaunchAtLogin.needsApproval
    @State private var error: String?

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { isOn }, set: change))
            .onAppear(perform: refresh)
        if needsApproval {
            HStack {
                Text("Allow Cheetsheet in Login Items to finish turning this on.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .controlSize(.small)
            }
        }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private func change(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            error = nil
        } catch {
            self.error = "Couldn't change this: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        isOn = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval
        needsApproval = LaunchAtLogin.needsApproval
    }
}
