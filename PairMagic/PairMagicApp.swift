import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let args = CommandLine.arguments
        if args.contains("--dump-bluetooth-settings") { SettingsAutomator.dumpBluetoothPane() }
        if args.contains("--show-settings") { SettingsWindowController.shared.show() }
        if args.contains("--mock-popups") { PairingCoordinator.shared.showAllMockPopups() }
        if let i = args.firstIndex(of: "--mock-popup"), i + 1 < args.count,
           let mock = MockPopup(rawValue: args[i + 1]) {
            PairingCoordinator.shared.showMockPopup(mock)
        }
        #endif
        _ = Updater.shared // starts Sparkle's scheduled update checks
        // Wait a moment so a first-run Bluetooth prompt has appeared and the
        // authorization state has settled before deciding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if PermissionsWindowController.needsAttention(autoConfirm: PairingCoordinator.shared.needsAccessibility) {
                PermissionsWindowController.shared.show()
            }
        }
    }
}

@main
struct PairMagicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = PairingCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: coordinator, updater: .shared)
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var coordinator: PairingCoordinator
    @ObservedObject var updater: Updater

    var body: some View {
        if !coordinator.bluetoothPoweredOn {
            Text("Bluetooth is off")
        } else if !coordinator.isScanning {
            Text("Scanning paused")
        } else if coordinator.nearby.isEmpty {
            Text("Looking for devices in pairing mode…")
        } else {
            Section("Ready to pair") {
                ForEach(coordinator.nearby, id: \.id) { device in
                    Button {
                        coordinator.showPopup(for: device)
                    } label: {
                        Label(device.displayName, systemImage: device.kind.symbol)
                    }
                }
            }
        }

        if coordinator.isRemovingDuplicates {
            Text("Removing old pairings…")
        } else if coordinator.duplicateCount > 0 {
            Button("Remove \(coordinator.duplicateCount) Disconnected Duplicate\(coordinator.duplicateCount == 1 ? "" : "s")") {
                coordinator.removeDisconnectedDuplicates()
            }
        }

        if coordinator.needsAccessibility && !coordinator.accessibilityTrusted {
            Button("Allow Accessibility Access…") { PermissionsWindowController.shared.show() }
        }

        Divider()

        Toggle("Scan for Devices", isOn: $coordinator.isScanning)

        Divider()

        Button("Bluetooth Settings…") { coordinator.openBluetoothSettings() }

        Divider()

        Button("Settings…") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)

        Divider()

        #if DEBUG
        Menu("Debug") {
            Section("Mock Popups") {
                ForEach(MockPopup.allCases) { mock in
                    Button(mock.label) { coordinator.showMockPopup(mock) }
                }
                Button("Show All") { coordinator.showAllMockPopups() }
            }
        }

        Divider()
        #endif

        Button("About PairMagic") { AboutPanel.show() }
        Button("Quit PairMagic") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The standard macOS About panel (icon, name, version, copyright), with credits
/// describing the app and linking to its source.
enum AboutPanel {
    static let repositoryURL = URL(string: "https://github.com/kristenadd/PairMagic")!

    static func show() {
        // Menu bar apps aren't active by default, so bring the panel forward explicitly.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Make every accessory magic.\n", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]))
        text.append(NSAttributedString(string: """
            PairMagic watches for Bluetooth keyboards, mice, game controllers and headsets in \
            pairing mode and pairs them with one click. Everything happens on your Mac.\n
            """, attributes: body))
        var link = body
        link[.link] = repositoryURL
        text.append(NSAttributedString(string: "github.com/kristenadd/PairMagic", attributes: link))
        return text
    }
}
