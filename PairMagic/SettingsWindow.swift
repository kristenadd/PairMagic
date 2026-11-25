import AppKit
import Combine
import SwiftUI

/// The app's Settings window: a standard macOS toolbar-tabbed preferences window
/// (General, Devices, Pairing, Updates). Opened from the menu bar with Settings… (⌘,).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private static let selectedTabKey = "settingsSelectedTab"

    func show() {
        if window == nil { window = makeWindow() }
        // Menu bar apps aren't active by default, so bring the window forward explicitly.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let coordinator = PairingCoordinator.shared
        let tabs = SettingsTabController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        tabs.addTabViewItem(Self.tab("General", symbol: "gearshape",
                             GeneralSettingsView(coordinator: coordinator)))
        tabs.addTabViewItem(Self.tab("Devices", symbol: "keyboard",
                             DeviceSettingsView(coordinator: coordinator)))
        tabs.addTabViewItem(Self.tab("Pairing", symbol: "link",
                             PairingSettingsView(coordinator: coordinator)))
        tabs.addTabViewItem(Self.tab("Updates", symbol: "arrow.triangle.2.circlepath",
                             UpdateSettingsView(updater: .shared)))
        let saved = UserDefaults.standard.integer(forKey: Self.selectedTabKey)
        tabs.selectedTabViewItemIndex = tabs.tabViewItems.indices.contains(saved) ? saved : 0
        tabs.onSelect = { UserDefaults.standard.set($0, forKey: Self.selectedTabKey) }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("PairMagicSettings")
        if !window.setFrameUsingName("PairMagicSettings") { window.center() }
        return window
    }

    private static func tab<Content: View>(_ title: String, symbol: String, _ content: Content) -> NSTabViewItem {
        let host = NSHostingController(rootView: content.frame(width: 520).fixedSize(horizontal: false, vertical: true))
        host.sizingOptions = [.preferredContentSize]
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// Remembers which tab was last selected.
private final class SettingsTabController: NSTabViewController {
    var onSelect: ((Int) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?(selectedTabViewItemIndex)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var coordinator: PairingCoordinator

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $coordinator.launchAtLogin)
            } footer: {
                SettingsFootnote("To launch at login, PairMagic must be in your Applications folder.")
            }

            Section("Discovery") {
                Toggle("Scan for devices in pairing mode", isOn: $coordinator.isScanning)
                Toggle("Pop up when a device appears", isOn: $coordinator.autoPopup)
                Toggle(isOn: $coordinator.nearbyOnly) {
                    Text("Only pop up for devices right next to this Mac")
                    Text("Devices farther away are still listed in the menu bar.")
                }
                .disabled(!coordinator.autoPopup)
            }

            Section {
                LabeledContent("Bluetooth") {
                    Button("Open Bluetooth Settings…") { coordinator.openBluetoothSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Devices

struct DeviceSettingsView: View {
    @ObservedObject var coordinator: PairingCoordinator

    var body: some View {
        Form {
            Section {
                Toggle("Show all device types", isOn: $coordinator.showAllTypes)
                ForEach(DeviceCategory.choices) { category in
                    Toggle(isOn: Binding(
                        get: { coordinator.isShowing(category) },
                        set: { coordinator.setShowing(category, $0) }
                    )) {
                        Label(category.label, systemImage: category.symbol)
                    }
                    .disabled(coordinator.showAllTypes)
                }
            } header: {
                Text("Device Types")
            } footer: {
                SettingsFootnote("PairMagic only offers to pair the types of device you choose here.")
            }

            Section {
                if coordinator.ignored.isEmpty {
                    Text("No ignored devices")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.ignored) { device in
                        HStack {
                            Label(device.name, systemImage: device.kind.symbol)
                            Spacer()
                            Button("Stop Ignoring") { coordinator.unignore(device.id) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Ignored Devices")
                    Spacer()
                    if !coordinator.ignored.isEmpty {
                        Button("Stop Ignoring All") { coordinator.clearIgnored() }
                            .controlSize(.small)
                    }
                }
            } footer: {
                SettingsFootnote("Devices you ignore from a pairing popup never pop up again until you stop ignoring them.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Pairing

struct PairingSettingsView: View {
    @ObservedObject var coordinator: PairingCoordinator

    @State private var accessibility = PromptAutoConfirmer.isTrusted
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $coordinator.autoConfirmPrompt) {
                    Text("Automatically confirm the macOS pairing prompt")
                    Text("Presses Connect on the system alert, only for a device you just chose to pair.")
                }
                Toggle(isOn: Binding(
                    get: { coordinator.replaceSameName },
                    set: { coordinator.setReplaceSameName($0) }
                )) {
                    HStack(spacing: 6) {
                        Text("Replace paired devices with the same name")
                        Text("Experimental")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Text("Removes older, disconnected pairings with the same name when a device pairs.")
                }
            } header: {
                Text("When Pairing")
            }

            Section {
                LabeledContent("Old pairings") {
                    if coordinator.isRemovingDuplicates {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Removing…").foregroundStyle(.secondary)
                        }
                    } else if coordinator.duplicateCount > 0 {
                        Button("Remove \(coordinator.duplicateCount) Disconnected Duplicate\(coordinator.duplicateCount == 1 ? "" : "s")") {
                            coordinator.removeDisconnectedDuplicates()
                        }
                    } else {
                        Text("No duplicates").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                SettingsFootnote("Disconnected pairings that share a name with a connected device.")
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack(spacing: 8) {
                        if coordinator.needsAccessibility {
                            if accessibility {
                                Label("Allowed", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Label("Not allowed", systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        } else {
                            Text("Not needed").foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("") {
                    Button("Review Permissions…") { PermissionsWindowController.shared.show() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onReceive(refresh) { _ in accessibility = PromptAutoConfirmer.isTrusted }
    }
}

// MARK: - Updates

struct UpdateSettingsView: View {
    @ObservedObject var updater: Updater

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Current version", value: version)
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                LabeledContent("") {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } footer: {
                SettingsFootnote("PairMagic checks once a day and asks before installing anything.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Shared

private struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
