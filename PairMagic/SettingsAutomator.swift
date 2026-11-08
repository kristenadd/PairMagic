import AppKit
import ApplicationServices
import os

/// Drives System Settings › Bluetooth through the Accessibility API.
///
/// macOS ignores unpair requests from third-party apps, so the only way to remove
/// an old pairing is to have System Settings do it ("Forget This Device").
final class SettingsAutomator {
    private static let log = Logger(subsystem: "com.kristenadd.PairMagic", category: "Settings")
    static let settingsBundleID = "com.apple.systempreferences"

    static func openBluetoothPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    static var settingsApp: AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private var openedSettings = false

    /// Opens the Bluetooth pane and waits for its device list.
    func begin(completion: @escaping (Bool) -> Void) {
        openedSettings = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).isEmpty
        Self.openBluetoothPane()
        Self.waitFor(timeout: 10, { Self.deviceRows().isEmpty ? nil : true }) { found in
            if found == nil { Self.log.error("Bluetooth Settings didn't show its device list") }
            completion(found != nil)
        }
    }

    /// Closes any detail sheet left open, and quits Settings if we opened it.
    func end() {
        Self.dismissSheets()
        if openedSettings {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).forEach { $0.terminate() }
        }
    }

    /// Forgets one "Not Connected" device named exactly `name`. Reports false if
    /// there was none, or any step didn't go as expected.
    func forgetOneDisconnected(named name: String, completion: @escaping (Bool) -> Void) {
        Self.dismissSheets()
        func disconnectedRows() -> [DeviceRow] {
            Self.deviceRows().filter { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.status == "Not Connected" }
        }
        let before = disconnectedRows()
        guard let row = before.first else {
            Self.log.notice("No disconnected “\(name, privacy: .public)” row in Bluetooth Settings")
            completion(false)
            return
        }
        guard AX.perform(row.detailButton, kAXPressAction) else { completion(false); return }

        // The detail sheet: check it's for this device before forgetting it.
        Self.waitFor(timeout: 4, { Self.forgetButtonInDetailSheet(named: name) }) { forget in
            guard let forget, AX.perform(forget, kAXPressAction) else {
                Self.log.error("Couldn't find Forget This Device… for “\(name, privacy: .public)”")
                completion(false)
                return
            }
            // Some macOS versions ask to confirm; others forget straight away.
            var confirmed = false
            Self.waitFor(timeout: 6, { () -> Bool? in
                if !confirmed, let confirm = Self.confirmForgetButton(), AX.perform(confirm, kAXPressAction) {
                    confirmed = true
                }
                let rows = Self.deviceRows()
                // An empty list means the pane is still redrawing.
                return !rows.isEmpty && disconnectedRows().count < before.count ? true : nil
            }) { gone in
                if gone == nil {
                    Self.log.error("“\(name, privacy: .public)” is still listed after Forget This Device…")
                    Self.logWindows()
                    completion(false)
                } else {
                    Self.log.notice("Forgot a disconnected “\(name, privacy: .public)” in Bluetooth Settings\(confirmed ? " (confirmed)" : "", privacy: .public)")
                    completion(true)
                }
            }
        }
    }

    // MARK: Finding things

    private struct DeviceRow {
        let name: String
        let status: String
        let detailButton: AXUIElement
    }

    /// The "My Devices" list is a flat group of (name, status, Show Detail) triples.
    private static func deviceRows() -> [DeviceRow] {
        guard let window = mainWindow else { return [] }
        var rows: [DeviceRow] = []
        for group in descendants(of: window) where AX.string(group, kAXRoleAttribute) == kAXGroupRole as String {
            let kids = AX.children(of: group, attribute: kAXChildrenAttribute)
            var i = 0
            while i + 2 < kids.count {
                if AX.string(kids[i + 2], kAXRoleAttribute) == kAXButtonRole as String,
                   AX.string(kids[i + 2], kAXDescriptionAttribute) == "Show Detail",
                   let name = AX.string(kids[i], kAXValueAttribute),
                   let status = AX.string(kids[i + 1], kAXValueAttribute) {
                    rows.append(DeviceRow(name: name, status: status, detailButton: kids[i + 2]))
                    i += 3
                } else {
                    i += 1
                }
            }
        }
        return rows
    }

    private static var mainWindow: AXUIElement? {
        guard let app = settingsApp else { return nil }
        let windows = AX.children(of: app, attribute: kAXWindowsAttribute)
        return windows.first { AX.string($0, kAXIdentifierAttribute) == "Main" } ?? windows.first
    }

    private static func sheets() -> [AXUIElement] {
        guard let app = settingsApp else { return [] }
        return AX.children(of: app, attribute: kAXWindowsAttribute).flatMap { window in
            [window].flatMap(descendants).filter { AX.string($0, kAXRoleAttribute) == kAXSheetRole as String }
        }
    }

    private static func forgetButtonInDetailSheet(named name: String) -> AXUIElement? {
        for sheet in sheets() {
            let elements = descendants(of: sheet)
            let isThisDevice = elements.contains {
                AX.string($0, kAXValueAttribute)?.caseInsensitiveCompare(name) == .orderedSame
            }
            if isThisDevice, let button = elements.first(where: { label(of: $0)?.hasPrefix("Forget This Device") == true }) {
                return button
            }
        }
        return nil
    }

    /// The confirmation's "Forget" button (not the detail sheet's "Forget This Device…").
    private static func confirmForgetButton() -> AXUIElement? {
        guard let app = settingsApp else { return nil }
        let candidates = AX.children(of: app, attribute: kAXWindowsAttribute).flatMap(descendants)
            .filter { AX.string($0, kAXRoleAttribute) == kAXButtonRole as String }
        let button = candidates.first { element in
            guard let label = label(of: element)?.lowercased() else { return false }
            return label.hasPrefix("forget") && !label.hasPrefix("forget this device")
        }
        return button
    }

    /// Logs every Settings window's elements, for when a step can't be found.
    private static func logWindows() {
        guard let app = settingsApp else { return }
        for window in AX.children(of: app, attribute: kAXWindowsAttribute) {
            let lines = ([window] + descendants(of: window)).map { element in
                [AX.string(element, kAXRoleAttribute), AX.string(element, kAXSubroleAttribute),
                 AX.string(element, kAXIdentifierAttribute), label(of: element), AX.string(element, kAXValueAttribute)]
                    .compactMap { $0 }.joined(separator: " ")
            }
            log.notice("Window: \(lines.joined(separator: " | "), privacy: .public)")
        }
    }

    private static func dismissSheets() {
        for sheet in sheets() {
            if let done = descendants(of: sheet).first(where: { label(of: $0) == "Done" || label(of: $0) == "Cancel" }) {
                AX.perform(done, kAXPressAction)
            }
        }
    }

    private static func label(of element: AXUIElement) -> String? {
        AX.string(element, kAXTitleAttribute) ?? AX.string(element, kAXDescriptionAttribute)
    }

    private static func descendants(of element: AXUIElement) -> [AXUIElement] {
        descendants(of: element, depth: 0)
    }

    private static func descendants(of element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth < 30 else { return [] }
        let kids = AX.children(of: element, attribute: kAXChildrenAttribute)
        return kids + kids.flatMap { descendants(of: $0, depth: depth + 1) }
    }

    /// Polls `condition` on the main queue until it returns a value or time runs out.
    private static func waitFor<T>(timeout: TimeInterval, _ condition: @escaping () -> T?, then: @escaping (T?) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if let value = condition() { then(value); return }
            guard Date() < deadline else { then(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
        }
        poll()
    }

    #if DEBUG
    /// Logs the Settings window's accessibility tree (launch with
    /// `--dump-bluetooth-settings`), to work out how to drive it.
    static func dumpBluetoothPane() {
        openBluetoothPane()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard let app = settingsApp else { log.notice("DUMP: Settings not running"); return }
            for window in AX.children(of: app, attribute: kAXWindowsAttribute) {
                dump(window, depth: 0)
            }
            log.notice("DUMP: done")
        }
    }

    private static func dump(_ element: AXUIElement, depth: Int) {
        guard depth < 30 else { return }
        let parts = [
            AX.string(element, kAXRoleAttribute),
            AX.string(element, kAXSubroleAttribute).map { "sub=\($0)" },
            AX.string(element, kAXIdentifierAttribute).map { "id=\($0)" },
            AX.string(element, kAXTitleAttribute).map { "title=\($0)" },
            AX.string(element, kAXDescriptionAttribute).map { "desc=\($0)" },
            AX.string(element, kAXValueAttribute).map { "value=\($0)" },
            AX.actions(element).filter { $0 != kAXShowMenuAction as String && $0 != "AXScrollToVisible" }
                .nilIfEmpty.map { "actions=\($0.joined(separator: ","))" },
        ].compactMap { $0 }
        log.notice("DUMP: \(String(repeating: "  ", count: depth), privacy: .public)\(parts.joined(separator: " "), privacy: .public)")
        for child in AX.children(of: element, attribute: kAXChildrenAttribute) {
            dump(child, depth: depth + 1)
        }
    }
    #endif
}

/// Small wrappers around the Accessibility C API.
enum AX {
    static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
