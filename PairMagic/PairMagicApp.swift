import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--dump-bluetooth-settings") { SettingsAutomator.dumpBluetoothPane() }
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

        if !coordinator.ignored.isEmpty {
            Menu("Ignored Devices") {
                Section("Click a device to stop ignoring it") {
                    ForEach(coordinator.ignored) { device in
                        Button {
                            coordinator.unignore(device.id)
                        } label: {
                            Label(device.name, systemImage: device.kind.symbol)
                        }
                    }
                }
                Divider()
                Button("Stop Ignoring All") { coordinator.clearIgnored() }
            }
        }

        if coordinator.isRemovingDuplicates {
            Text("Removing old pairings…")
        } else if coordinator.duplicateCount > 0 {
            Button("Remove \(coordinator.duplicateCount) Disconnected Duplicate\(coordinator.duplicateCount == 1 ? "" : "s")") {
                coordinator.removeDisconnectedDuplicates()
            }
        }

        Divider()

        Toggle("Scan for Devices", isOn: $coordinator.isScanning)
        Toggle("Pop Up When a Device Appears", isOn: $coordinator.autoPopup)
        Toggle("Only Pop Up for Nearby Devices", isOn: $coordinator.nearbyOnly)
            .disabled(!coordinator.autoPopup)
        Toggle("Replace Paired Devices with the Same Name (Experimental)", isOn: Binding(
            get: { coordinator.replaceSameName },
            set: { coordinator.setReplaceSameName($0) }
        ))
        Toggle("Auto-Confirm macOS Pairing Prompt", isOn: $coordinator.autoConfirmPrompt)
        if coordinator.needsAccessibility && !coordinator.accessibilityTrusted {
            Button("    Allow Accessibility Access…") { PermissionsWindowController.shared.show() }
        }
        Toggle("Launch at Login", isOn: $coordinator.launchAtLogin)

        Menu("Device Types") {
            ForEach(DeviceCategory.choices) { category in
                Toggle(isOn: Binding(
                    get: { coordinator.isShowing(category) },
                    set: { coordinator.setShowing(category, $0) }
                )) {
                    Label(category.label, systemImage: category.symbol)
                }
                .disabled(coordinator.showAllTypes)
            }
            Divider()
            Toggle("Show All Device Types", isOn: $coordinator.showAllTypes)
        }

        Divider()

        Button("Permissions…") { PermissionsWindowController.shared.show() }
        Button("Bluetooth Settings…") { coordinator.openBluetoothSettings() }

        Divider()

        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        Toggle("Automatically Check for Updates", isOn: $updater.automaticallyChecks)
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
