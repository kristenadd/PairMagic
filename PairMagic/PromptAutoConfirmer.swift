import AppKit
import ApplicationServices
import os

/// Presses "Connect" on the macOS Bluetooth pairing alert, using the Accessibility API.
///
/// It is deliberately narrow: it only runs for a short window after the user clicks
/// Pair in this app, and only clicks an alert whose text names the device being
/// paired. Any other pairing request still needs the user's approval.
final class PromptAutoConfirmer {
    private static let log = Logger(subsystem: "com.kristenadd.PairMagic", category: "AutoConfirm")

    /// System processes that have shown Bluetooth pairing alerts on recent macOS.
    private static let alertOwners: Set<String> = [
        "com.apple.BluetoothUIServer",
        "com.apple.BluetoothUIService",
        "com.apple.UserNotificationCenter",
        "com.apple.notificationcenterui",
    ]
    private static let confirmTitles = ["connect", "pair", "allow", "accept"]

    private var timer: Timer?
    private var deviceName = ""
    private var deadline = Date.distantPast

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt if the app isn't trusted yet.
    @discardableResult
    static func requestAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Watches for the alert for `duration` seconds. Does nothing without a device
    /// name, since the name is the only way to tell our alert from anyone else's.
    func watch(forDeviceNamed name: String?, duration: TimeInterval = 30) {
        stop()
        guard let name, !name.isEmpty else { return }
        guard Self.isTrusted else {
            Self.log.info("Not trusted for Accessibility; leaving the pairing prompt to the user")
            return
        }
        deviceName = name.lowercased()
        deadline = Date().addingTimeInterval(duration)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard Date() < deadline else { stop(); return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            Self.alertOwners.contains($0.bundleIdentifier ?? "")
        }
        for app in apps where confirm(in: AXUIElementCreateApplication(app.processIdentifier), owner: app.bundleIdentifier ?? "?") {
            stop()
            return
        }
    }

    /// Looks through each window of `appElement` for one that mentions the device and
    /// has a confirm button (or a notification "Connect" action), then presses it.
    private func confirm(in appElement: AXUIElement, owner: String) -> Bool {
        for window in children(of: appElement, attribute: kAXWindowsAttribute) {
            var texts: [String] = []
            var buttons: [(element: AXUIElement, title: String)] = []
            var actions: [(element: AXUIElement, name: String)] = []
            collect(window, depth: 0, texts: &texts, buttons: &buttons, actions: &actions)

            guard texts.contains(where: { $0.lowercased().contains(deviceName) }) else { continue }
            Self.log.info("Found alert from \(owner, privacy: .public): \(texts.joined(separator: " | "), privacy: .public)")

            if let button = buttons.first(where: { Self.confirmTitles.contains($0.title.lowercased()) }) {
                let result = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
                Self.log.info("Pressed \(button.title, privacy: .public): \(result.rawValue)")
                if result == .success { return true }
            }
            // Notification banners expose their buttons as custom actions instead.
            if let action = actions.first(where: { action in
                Self.confirmTitles.contains { action.name.lowercased().contains("name:\($0)") }
            }) {
                let result = AXUIElementPerformAction(action.element, action.name as CFString)
                Self.log.info("Performed action \(action.name, privacy: .public): \(result.rawValue)")
                if result == .success { return true }
            }
            Self.log.info("No confirm button found; buttons: \(buttons.map(\.title).joined(separator: ", "), privacy: .public)")
        }
        return false
    }

    private func collect(_ element: AXUIElement, depth: Int, texts: inout [String],
                         buttons: inout [(element: AXUIElement, title: String)],
                         actions: inout [(element: AXUIElement, name: String)]) {
        guard depth < 12 else { return }
        let role = string(of: element, attribute: kAXRoleAttribute)
        for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            if let text = string(of: element, attribute: attribute), !text.isEmpty { texts.append(text) }
        }
        if role == kAXButtonRole as String, let title = string(of: element, attribute: kAXTitleAttribute)
            ?? string(of: element, attribute: kAXDescriptionAttribute) {
            buttons.append((element, title))
        }
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let names = names as? [String] {
            for name in names where name.hasPrefix("Name:") { actions.append((element, name)) }
        }
        for child in children(of: element, attribute: kAXChildrenAttribute) {
            collect(child, depth: depth + 1, texts: &texts, buttons: &buttons, actions: &actions)
        }
    }

    private func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func string(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
