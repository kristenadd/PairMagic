import Foundation
import IOBluetooth
import os

/// Events reported while pairing, shared by the Classic and LE pairers.
enum PairingEvent {
    case status(String)
    /// The user must type this code on the device (keyboards), then press Return.
    case typeCode(String)
    /// Numeric comparison code, shown for information; we auto-confirm because the
    /// user already clicked Pair.
    case confirmCode(String)
    case succeeded
    case failed(String)
    /// Something went wrong that doesn't stop pairing, e.g. an old pairing that
    /// couldn't be removed.
    case warning(String)
}

/// Repeatedly runs Bluetooth Classic inquiries. Inquiry only finds devices that are
/// discoverable, which for keyboards, mice, controllers and headsets means "in
/// pairing mode".
final class ClassicScanner: NSObject, IOBluetoothDeviceInquiryDelegate {
    var onDevice: ((IOBluetoothDevice) -> Void)?

    private var inquiry: IOBluetoothDeviceInquiry!
    private var isRunning = false
    private var wantsToRun = false

    override init() {
        super.init()
        inquiry = IOBluetoothDeviceInquiry(delegate: self)
        inquiry.inquiryLength = 8
        inquiry.updateNewDeviceNames = true
    }

    func start() {
        wantsToRun = true
        startCycle()
    }

    func stop() {
        wantsToRun = false
        if isRunning { inquiry.stop() }
    }

    private func startCycle() {
        guard wantsToRun, !isRunning else { return }
        // Clearing means every cycle reports devices again, which keeps lastSeen fresh.
        inquiry.clearFoundDevices()
        if inquiry.start() == kIOReturnSuccess {
            isRunning = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startCycle() }
        }
    }

    func deviceInquiryStarted(_ sender: IOBluetoothDeviceInquiry!) {
        isRunning = true
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        if let device { onDevice?(device) }
    }

    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        if let device { onDevice?(device) }
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        isRunning = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startCycle() }
    }
}

/// Pairs a single Bluetooth Classic device using IOBluetoothDevicePair.
final class ClassicPairer: NSObject, IOBluetoothDevicePairDelegate {
    private let device: IOBluetoothDevice
    private let isKeyboard: Bool
    private var pair: IOBluetoothDevicePair?
    private var onEvent: ((PairingEvent) -> Void)?

    init(device: IOBluetoothDevice, isKeyboard: Bool) {
        self.device = device
        self.isKeyboard = isKeyboard
    }

    func start(onEvent: @escaping (PairingEvent) -> Void) {
        self.onEvent = onEvent
        guard let pair = IOBluetoothDevicePair(device: device) else {
            onEvent(.failed("Couldn't start pairing."))
            return
        }
        self.pair = pair
        pair.delegate = self
        let result = pair.start()
        if result != kIOReturnSuccess {
            onEvent(.failed("Couldn't start pairing (\(BluetoothSystem.describe(result)))."))
        }
    }

    func cancel() {
        pair?.stop()
        pair = nil
    }

    func devicePairingStarted(_ sender: Any!) {
        onEvent?(.status("Pairing…"))
    }

    func devicePairingConnecting(_ sender: Any!) {
        onEvent?(.status("Connecting…"))
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        // Legacy (pre-2.1) pairing. Keyboards need a code typed on them; most other
        // simple devices use the fixed PIN 0000.
        let code = isKeyboard ? String(format: "%06d", Int.random(in: 0...999_999)) : "0000"
        if isKeyboard { onEvent?(.typeCode(code)) }

        var pin = BluetoothPINCode()
        withUnsafeMutableBytes(of: &pin) { buffer in
            for (i, byte) in code.utf8.enumerated() { buffer[i] = byte }
        }
        pair?.replyPINCode(code.utf8.count, pinCode: &pin)
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        onEvent?(.confirmCode(String(format: "%06u", numericValue)))
        pair?.replyUserConfirmation(true)
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        onEvent?(.typeCode(String(format: "%06u", passkey)))
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        pair = nil
        guard error == kIOReturnSuccess else {
            onEvent?(.failed("Pairing failed (\(BluetoothSystem.describe(error))). Make sure the device is still in pairing mode."))
            return
        }
        // Bring the connection up so the HID / audio profile attaches right away.
        onEvent?(.status("Connecting…"))
        _ = device.openConnection()
        onEvent?(.succeeded)
    }
}

/// One entry in the system's paired-device list (Classic and LE alike).
struct PairedEntry {
    let name: String?
    /// Lowercase hex address, e.g. "d1e1691a6c37".
    let key: String
    let isConnected: Bool
    let device: IOBluetoothDevice

    var displayName: String { name ?? key }
}

/// Helpers around the system's list of paired devices.
enum BluetoothSystem {
    private static let log = Logger(subsystem: "com.kristenadd.PairMagic", category: "Unpair")

    static var pairedDevices: [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    static func pairedEntries() -> [PairedEntry] {
        pairedDevices.compactMap { device in
            guard let address = device.addressString.map(normalized) else { return nil }
            return PairedEntry(name: device.name, key: address, isConnected: device.isConnected(), device: device)
        }
    }

    /// Paired entries whose name matches an advertised name (see `namesMatch`).
    static func entries(named name: String?) -> [PairedEntry] {
        guard let name, !name.isEmpty else { return [] }
        return pairedEntries().filter { $0.name.map { namesMatch(advertised: name, stored: $0) } ?? false }
    }

    /// LE devices often advertise a shortened name ("Logi M550") while macOS
    /// stores the full one ("Logi M550 L"), so a prefix counts as a match.
    static func namesMatch(advertised: String, stored: String) -> Bool {
        let advertised = advertised.trimmingCharacters(in: .whitespaces).lowercased()
        let stored = stored.trimmingCharacters(in: .whitespaces).lowercased()
        if advertised == stored { return true }
        return advertised.count >= 4 && stored.hasPrefix(advertised)
    }

    static func entry(withAddress address: String?) -> PairedEntry? {
        guard let address = address.map(normalized) else { return nil }
        return pairedEntries().first { $0.key == address }
    }

    /// Disconnected pairings that share a name with a connected one, e.g. the
    /// old addresses a Logitech mouse leaves behind each time it re-pairs.
    static func disconnectedDuplicates() -> [PairedEntry] {
        let byName = Dictionary(grouping: pairedEntries().filter { $0.name != nil }) { $0.name!.lowercased() }
        return byName.values
            .filter { group in group.count > 1 && group.contains(where: \.isConnected) }
            .flatMap { $0.filter { !$0.isConnected } }
    }

    /// Logs the paired list, to diagnose replace/unpair problems.
    static func logInventory() {
        let entries = pairedEntries().map { "\($0.displayName) \($0.key) connected=\($0.isConnected)" }
        log.notice("Paired: \(entries.joined(separator: "; "), privacy: .public)")
    }

    /// Removes pairings and reports the names of any that couldn't be removed.
    ///
    /// Apple has no public unpair API. The private `-[IOBluetoothDevice remove]`
    /// (the selector blueutil uses) is tried first, but recent macOS silently
    /// ignores it (and CoreBluetooth's `-[CBPairingAgent unpairPeer:]`) from
    /// third-party apps. Whatever survives is forgotten through System Settings,
    /// which needs Accessibility access. Each removal is confirmed against the
    /// paired list.
    static func unpair(_ entries: [PairedEntry], completion: @escaping (_ failed: [String]) -> Void) {
        guard !entries.isEmpty else { completion([]); return }
        for entry in entries { _ = perform("remove", on: entry.device) }
        // bluetoothd updates the paired list asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let remaining = entries.filter { entry(withAddress: $0.key) != nil }
            guard !remaining.isEmpty else {
                log.notice("Removed \(entries.count) pairing(s) with IOBluetoothDevice.remove")
                completion([])
                return
            }
            guard PromptAutoConfirmer.isTrusted else {
                log.error("Can't remove \(remaining.count) pairing(s): no Accessibility access for System Settings")
                completion(remaining.map(\.displayName))
                return
            }
            forgetInSettings(remaining, completion: completion)
        }
    }

    /// Forgets disconnected same-named rows in System Settings until every target
    /// address is gone. Rows don't show addresses, so with several identically
    /// named pairings any disconnected one may be picked; each pass re-checks
    /// which targets remain.
    private static func forgetInSettings(_ targets: [PairedEntry], completion: @escaping (_ failed: [String]) -> Void) {
        let automator = SettingsAutomator()
        var passesLeft = targets.count + 2

        func remaining() -> [PairedEntry] { targets.filter { entry(withAddress: $0.key) != nil } }

        func finish() {
            automator.end()
            let failed = remaining()
            if failed.isEmpty {
                log.notice("Forgot \(targets.count) pairing(s) in System Settings")
            } else {
                log.error("\(failed.count) pairing(s) still present after System Settings: \(failed.map(\.key).joined(separator: ", "), privacy: .public)")
            }
            completion(failed.map(\.displayName))
        }

        func next() {
            guard let target = remaining().first, let name = target.name, passesLeft > 0 else { finish(); return }
            passesLeft -= 1
            automator.forgetOneDisconnected(named: name) { forgot in
                if forgot { next() } else { finish() }
            }
        }

        automator.begin { ready in
            if ready { next() } else { finish() }
        }
    }

    static func normalized(_ address: String) -> String {
        address.lowercased().filter(\.isHexDigit)
    }

    private static func perform(_ selectorName: String, on device: IOBluetoothDevice) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard device.responds(to: selector) else { return false }
        device.perform(selector)
        return true
    }

    static func replaceWarning(_ failed: [String]) -> String {
        let names = failed.map { "“\($0)”" }.joined(separator: ", ")
        return "Couldn’t remove the old pairing for \(names). Remove it in System Settings › Bluetooth."
    }

    static func describe(_ result: IOReturn) -> String {
        switch result {
        case kIOReturnTimeout: return "timed out"
        case kIOReturnNotPermitted, kIOReturnNotPrivileged: return "not permitted"
        default: return String(format: "error 0x%08X", UInt32(bitPattern: result))
        }
    }
}
