import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--dump-bluetooth-settings") { SettingsAutomator.dumpBluetoothPane() }
        #endif
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
            MenuContent(coordinator: coordinator)
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var coordinator: PairingCoordinator

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
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
