import AppKit
import Combine
import CoreBluetooth
import SwiftUI

/// A small setup window that walks the user through the permissions the app needs.
/// Shown at launch when something is missing, and from the menu bar at any time.
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    static let shared = PermissionsWindowController()

    private var window: NSWindow?

    /// True when a permission the current settings rely on hasn't been granted.
    static func needsAttention(autoConfirm: Bool) -> Bool {
        CBManager.authorization != .allowedAlways || (autoConfirm && !PromptAutoConfirmer.isTrusted)
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: PermissionsView(coordinator: .shared) { [weak self] in
                self?.window?.close()
            })
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "PairMagic Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // Menu bar apps aren't active by default, so bring the window forward explicitly.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct PermissionsView: View {
    @ObservedObject var coordinator: PairingCoordinator
    let onDone: () -> Void

    @State private var bluetooth = CBManager.authorization
    @State private var accessibility = PromptAutoConfirmer.isTrusted
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var allSet: Bool {
        bluetooth == .allowedAlways && (accessibility || !coordinator.needsAccessibility)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .overlay(alignment: .bottomTrailing) {
                        if allSet {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white, .green)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(allSet ? "You're all set" : "A couple of permissions to go")
                        .font(.title2.weight(.semibold))
                    Text("PairMagic needs these to find devices and pair them in one click.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PermissionRow(
                symbol: "dot.radiowaves.left.and.right",
                title: "Bluetooth",
                explanation: "Required. Lets the app see devices in pairing mode and pair them.",
                status: bluetoothStatus
            ) {
                switch bluetooth {
                case .notDetermined:
                    Text("Respond to the macOS prompt").font(.callout).foregroundStyle(.secondary)
                case .allowedAlways:
                    EmptyView()
                default:
                    Button("Open Settings…") { openPrivacyPane("Privacy_Bluetooth") }
                }
            }

            PermissionRow(
                symbol: "hand.tap",
                title: "Accessibility",
                explanation: "Optional. Lets the app press Connect on the macOS pairing prompt, only for a device you just clicked Pair on, and remove old pairings through System Settings when Replace Paired Devices (Experimental) is on.",
                status: coordinator.needsAccessibility ? (accessibility ? .granted : .missing) : .skipped
            ) {
                if coordinator.needsAccessibility && !accessibility {
                    HStack {
                        Button("Skip") {
                            coordinator.autoConfirmPrompt = false
                            coordinator.replaceSameName = false
                        }
                        Button("Allow…") {
                            // Shows the system prompt; if it was dismissed before, go to Settings.
                            if !PromptAutoConfirmer.requestAccess() { openPrivacyPane("Privacy_Accessibility") }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if !coordinator.needsAccessibility {
                    Button("Turn On") { coordinator.autoConfirmPrompt = true }
                }
            }

            if !accessibility && coordinator.needsAccessibility {
                Text("In System Settings, switch on PairMagic under Accessibility. This window updates on its own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(allSet ? "Done" : "Later", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(allSet ? .accentColor : .secondary)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onReceive(refresh) { _ in
            bluetooth = CBManager.authorization
            accessibility = PromptAutoConfirmer.isTrusted
        }
    }

    private var bluetoothStatus: PermissionStatus {
        switch bluetooth {
        case .allowedAlways: return .granted
        case .notDetermined: return .pending
        default: return .missing
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum PermissionStatus { case granted, missing, pending, skipped }

struct PermissionRow<Actions: View>: View {
    let symbol: String
    let title: String
    let explanation: String
    let status: PermissionStatus
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    badge
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .granted: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing: Label("Not allowed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .pending: Label("Waiting", systemImage: "clock").foregroundStyle(.orange)
        case .skipped: Label("Off", systemImage: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
