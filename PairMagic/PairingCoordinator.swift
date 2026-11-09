import AppKit
import CoreBluetooth
import Foundation
import IOBluetooth
import os
import ServiceManagement

/// One popup's worth of state: the device and how far pairing has got.
final class PairingSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case ready
        case working(String)
        case typeCode(String)
        case confirmCode(String)
        case succeeded
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .working, .typeCode, .confirmCode: return true
            default: return false
            }
        }
    }

    let id: String
    @Published var device: NearbyDevice
    @Published var state: State = .ready
    /// Describes the already-paired device(s) that pairing this one will replace.
    @Published var replacing: String?
    /// Shown alongside the result, e.g. when an old pairing couldn't be removed.
    @Published var warning: String?

    fileprivate var classicPairer: ClassicPairer?
    /// Keys of same-named pairings to remove once this one succeeds.
    fileprivate var oldPairings: Set<String> = []
    /// Keys of every pairing that existed when Pair was clicked.
    fileprivate var pairedBefore: Set<String> = []

    init(device: NearbyDevice) {
        self.id = device.id
        self.device = device
    }
}

/// A device the user chose to ignore. Saved so it stays ignored across launches.
struct IgnoredDevice: Codable, Identifiable {
    let id: String
    var name: String
    var kind: DeviceKind
}

/// Owns the scanners, decides when to pop up, and runs the pairing flow.
final class PairingCoordinator: ObservableObject {
    static let shared = PairingCoordinator()
    private static let log = Logger(subsystem: "com.kristenadd.PairMagic", category: "Discovery")

    @Published private(set) var nearby: [NearbyDevice] = []
    @Published private(set) var ignored: [IgnoredDevice] = [] {
        didSet { defaults.set(try? JSONEncoder().encode(ignored), forKey: Keys.ignored) }
    }
    @Published private(set) var bluetoothPoweredOn = true

    @Published var isScanning: Bool {
        didSet { defaults.set(isScanning, forKey: Keys.scanning); applyScanning() }
    }
    @Published var autoPopup: Bool {
        didSet { defaults.set(autoPopup, forKey: Keys.autoPopup) }
    }
    /// Only pop up for devices with a strong signal, i.e. right next to the Mac.
    /// Others are still listed in the menu.
    @Published var nearbyOnly: Bool {
        didSet { defaults.set(nearbyOnly, forKey: Keys.nearbyOnly); offerWaitingDevices() }
    }
    @Published var showAllTypes: Bool {
        didSet { defaults.set(showAllTypes, forKey: Keys.showAll); typeFilterChanged() }
    }
    /// Device types to offer when "Show All Device Types" is off.
    @Published var enabledCategories: Set<DeviceCategory> {
        didSet {
            defaults.set(enabledCategories.map(\.rawValue), forKey: Keys.categories)
            typeFilterChanged()
        }
    }
    @Published var replaceSameName: Bool {
        didSet { defaults.set(replaceSameName, forKey: Keys.replace); refreshReplacementInfo() }
    }
    @Published var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }
    /// Press "Connect" on the macOS alert that LE pairing shows (needs Accessibility).
    @Published var autoConfirmPrompt: Bool {
        didSet {
            defaults.set(autoConfirmPrompt, forKey: Keys.autoConfirm)
            if autoConfirmPrompt { requestAccessibility() }
        }
    }
    @Published private(set) var accessibilityTrusted = PromptAutoConfirmer.isTrusted
    /// Auto-confirm and same-name replacement both drive other apps' UI.
    var needsAccessibility: Bool { autoConfirmPrompt || replaceSameName }
    /// Disconnected pairings that share a name with a connected one.
    @Published private(set) var duplicateCount = 0
    @Published private(set) var isRemovingDuplicates = false

    private enum Keys {
        static let scanning = "scanning", autoPopup = "autoPopup", showAll = "showAllTypes", replace = "replaceSameName"
        static let ignored = "ignoredDevices", autoConfirm = "autoConfirmPrompt", categories = "deviceCategories"
        static let nearbyOnly = "nearbyOnly"
    }

    /// How long a device can go unseen before it's considered out of pairing mode
    /// (e.g. it paired with another computer). Its popup then closes as if the
    /// user clicked Not Now, so it pops up again the next time it enters pairing
    /// mode. Ignored devices never do. LE devices advertise many times a second,
    /// while a Classic device only answers once per ~9 second inquiry cycle, so
    /// Classic gets a few cycles of slack.
    private func staleAfter(_ device: NearbyDevice) -> TimeInterval {
        switch device.source {
        case .lowEnergy: return 8
        case .classic: return 30
        }
    }

    private let defaults = UserDefaults.standard
    private let classic = ClassicScanner()
    private let lowEnergy = LowEnergyScanner()
    private let popups = PopupManager()
    private let promptConfirmer = PromptAutoConfirmer()
    private var devices: [String: NearbyDevice] = [:]
    private var dismissed: Set<String> = []
    private var sessions: [String: PairingSession] = [:]
    private var activePairings = 0
    private var pruneTimer: Timer?

    /// LE devices that accepted a test connection, i.e. are really pairable now.
    /// LE devices are only offered once they're in here (see `verify`).
    private var verified: Set<String> = []
    private var probing: Set<String> = []
    private var lastProbe: [String: Date] = [:]
    /// A device that refused may be put into pairing mode while still advertising,
    /// so it's retried at this interval.
    private let reprobeInterval: TimeInterval = 15

    private init() {
        defaults.register(defaults: [Keys.scanning: true, Keys.autoPopup: true, Keys.showAll: false, Keys.replace: false,
                                     Keys.autoConfirm: true, Keys.nearbyOnly: true])
        autoConfirmPrompt = defaults.bool(forKey: Keys.autoConfirm)
        isScanning = defaults.bool(forKey: Keys.scanning)
        autoPopup = defaults.bool(forKey: Keys.autoPopup)
        nearbyOnly = defaults.bool(forKey: Keys.nearbyOnly)
        showAllTypes = defaults.bool(forKey: Keys.showAll)
        enabledCategories = (defaults.stringArray(forKey: Keys.categories)?.compactMap(DeviceCategory.init(rawValue:)))
            .map(Set.init) ?? Set(DeviceCategory.choices)
        replaceSameName = defaults.bool(forKey: Keys.replace)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if let data = defaults.data(forKey: Keys.ignored),
           let saved = try? JSONDecoder().decode([IgnoredDevice].self, from: data) {
            ignored = saved
        }

        classic.onDevice = { [weak self] in self?.ingestClassic($0) }
        lowEnergy.onDiscover = { [weak self] in self?.ingestLowEnergy($0, advertisement: $1, rssi: $2) }
        lowEnergy.onPoweredChange = { [weak self] poweredOn in
            guard let self else { return }
            self.bluetoothPoweredOn = poweredOn
            if poweredOn { BluetoothSystem.logInventory() }
        }
        popups.onClose = { [weak self] id in self?.sessionClosed(id) }

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.prune() }
        applyScanning()
    }

    // MARK: Scanning

    private func applyScanning() {
        if isScanning && activePairings == 0 {
            classic.start()
            lowEnergy.start()
        } else {
            classic.stop()
            lowEnergy.stop()
        }
    }

    private func ingestClassic(_ device: IOBluetoothDevice) {
        guard let address = device.addressString, !device.isConnected() else { return }
        let id = "bt:" + address
        let name = device.name
        let result = DeviceClassifier.classify(classOfDevice: device.classOfDevice, name: name)
        let rssi = Int(device.rawRSSI())

        // Dual-mode devices can show up over both transports; prefer Classic.
        if let name, let le = devices.values.first(where: { $0.address == nil && $0.name == name }) {
            devices[le.id] = nil
            if let session = sessions[le.id], !session.state.isBusy { popups.close(le.id) }
        }

        let updated = NearbyDevice(id: id, source: .classic(device), name: name, kind: result.kind,
                                   detail: result.detail, isInputDevice: result.isInputDevice,
                                   rssi: rssi, lastSeen: Date())
        upsert(updated)
    }

    private func ingestLowEnergy(_ peripheral: CBPeripheral, advertisement: [String: Any], rssi: Int) {
        if let connectable = advertisement[CBAdvertisementDataIsConnectable] as? Bool, !connectable { return }
        let id = "le:" + peripheral.identifier.uuidString
        let name = (advertisement[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let advertisedServices = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]

        // allowDuplicates delivers a stream of adverts; just refresh known ones.
        // Some devices keep advertising after pairing elsewhere but drop the HID
        // service, so only adverts that still look pairable count as "seen".
        // (Scan responses carry no service list and are ignored either way.)
        if var known = devices[id] {
            if let advertisedServices,
               DeviceClassifier.classify(advertisedServices: advertisedServices, name: name, includeUnknown: showAllTypes) != nil {
                known.lastSeen = Date()
                known.rssi = rssi
                devices[id] = known
                // It may have been too far away to pop up when first verified.
                offerIfWanted(known)
            }
            // The name often arrives in a later packet (the scan response). It's
            // needed to spot same-named pairings to replace, so pick it up.
            if known.name == nil, let name, !name.isEmpty {
                known.name = name
                upsert(known)
            }
            return
        }

        let services = advertisedServices ?? []
        guard let result = DeviceClassifier.classify(advertisedServices: services, name: name, includeUnknown: showAllTypes) else { return }
        if let name, devices.values.contains(where: { $0.address != nil && $0.name == name }) { return }

        upsert(NearbyDevice(id: id, source: .lowEnergy(peripheral), name: name, kind: result.kind,
                            detail: result.detail, isInputDevice: result.isInputDevice,
                            rssi: rssi, lastSeen: Date()))
    }

    private func upsert(_ device: NearbyDevice) {
        let isNew = devices[device.id] == nil
        devices[device.id] = device
        if let session = sessions[device.id] {
            session.device = device
            if !session.state.isBusy { session.replacing = replacementSummary(for: device) }
        }
        // A Classic device's name can arrive after it was first seen.
        if let index = ignored.firstIndex(where: { $0.id == device.id }),
           let name = device.name, !name.isEmpty, ignored[index].name != name {
            ignored[index].name = name
        }
        publishNearby()
        if isNew, case .lowEnergy = device.source, !verified.contains(device.id) {
            verify(device)
        } else {
            // New, or seen again by a later inquiry, possibly closer than before.
            offerIfWanted(device)
        }
    }

    /// Pops up a device that wants one but has no popup yet, e.g. one that just
    /// came close enough. Devices that were dismissed or ignored stay quiet.
    private func offerIfWanted(_ device: NearbyDevice) {
        if sessions[device.id] == nil, wantsPopup(device) {
            showPopup(for: device, playSound: true)
        }
    }

    /// Re-checks every device after a setting change, e.g. turning off "Only Pop
    /// Up for Nearby Devices" offers the farther ones that were held back.
    private func offerWaitingDevices() {
        for device in devices.values { offerIfWanted(device) }
    }

    private func shouldOffer(_ device: NearbyDevice) -> Bool {
        guard wantsType(device) else { return false }
        if case .lowEnergy = device.source { return verified.contains(device.id) }
        return true
    }

    private func wantsType(_ device: NearbyDevice) -> Bool {
        showAllTypes || enabledCategories.contains(device.category)
    }

    func isShowing(_ category: DeviceCategory) -> Bool {
        showAllTypes || enabledCategories.contains(category)
    }

    func setShowing(_ category: DeviceCategory, _ show: Bool) {
        if show { enabledCategories.insert(category) } else { enabledCategories.remove(category) }
    }

    /// Hides popups that are just waiting on the user for types that were turned off.
    private func typeFilterChanged() {
        for session in sessions.values where session.state == .ready && !wantsType(session.device) {
            popups.close(session.id)
        }
        publishNearby()
    }

    private func wantsPopup(_ device: NearbyDevice) -> Bool {
        autoPopup && shouldOffer(device) && !dismissed.contains(device.id) && !isIgnored(device.id)
            && (!nearbyOnly || device.isNearby)
    }

    /// Test-connects to an LE device and only offers it if it accepts (see
    /// `LowEnergyScanner.probe`). Ignored devices aren't probed at all.
    private func verify(_ device: NearbyDevice) {
        guard case .lowEnergy(let peripheral) = device.source, !probing.contains(device.id),
              !isIgnored(device.id), activePairings == 0,
              wantsType(device) else { return }
        probing.insert(device.id)
        lastProbe[device.id] = Date()
        lowEnergy.probe(peripheral) { [weak self] accepted in
            guard let self else { return }
            self.probing.remove(device.id)
            Self.log.info("Probe \(device.displayName, privacy: .public): \(accepted ? "accepted, offering it" : "refused, not in pairing mode", privacy: .public)")
            guard accepted, let current = self.devices[device.id] else { return }
            self.verified.insert(device.id)
            self.publishNearby()
            if self.wantsPopup(current) { self.showPopup(for: current, playSound: true) }
        }
    }

    private func prune() {
        let trusted = PromptAutoConfirmer.isTrusted
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        guard activePairings == 0 else { return }
        if !isRemovingDuplicates {
            let duplicates = BluetoothSystem.disconnectedDuplicates().count
            if duplicates != duplicateCount { duplicateCount = duplicates }
        }
        let now = Date()
        let stale = devices.values.filter { now.timeIntervalSince($0.lastSeen) > staleAfter($0) }.map(\.id)
        for device in devices.values where !verified.contains(device.id) && !stale.contains(device.id) {
            if now.timeIntervalSince(lastProbe[device.id] ?? .distantPast) > reprobeInterval { verify(device) }
        }
        guard !stale.isEmpty else { return }
        for id in stale {
            devices[id] = nil
            dismissed.remove(id)
            verified.remove(id)
            lastProbe[id] = nil
            if let session = sessions[id], session.state == .ready { popups.close(id) }
        }
        publishNearby()
    }

    private func publishNearby() {
        nearby = devices.values
            .filter { shouldOffer($0) && !isIgnored($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: Popups

    func showPopup(for device: NearbyDevice, playSound: Bool = false) {
        if sessions[device.id] != nil {
            if !playSound { popups.bringToFront(device.id) }
            return
        }
        let session = PairingSession(device: device)
        session.replacing = replacementSummary(for: device)
        Self.log.notice("Offering \(device.displayName, privacy: .public) (advertised name \(device.name ?? "none", privacy: .public), RSSI \(device.rssi.map(String.init) ?? "unknown", privacy: .public)): \(session.replacing ?? "nothing to replace", privacy: .public)")
        sessions[device.id] = session
        popups.show(session, coordinator: self)
        if playSound { NSSound(named: "Pop")?.play() }
    }

    /// Closes the popup. A cancelled device stays quiet only until it goes out of range.
    func dismiss(_ session: PairingSession) {
        if session.state != .succeeded { dismissed.insert(session.id) }
        popups.close(session.id)
    }

    // MARK: Ignored devices

    func isIgnored(_ id: String) -> Bool {
        ignored.contains { $0.id == id }
    }

    /// Closes the popup and never offers this device again until it's un-ignored.
    func ignore(_ session: PairingSession) {
        if !isIgnored(session.id) {
            ignored.append(IgnoredDevice(id: session.id, name: session.device.displayName, kind: session.device.kind))
        }
        popups.close(session.id)
        publishNearby()
    }

    func unignore(_ id: String) {
        ignored.removeAll { $0.id == id }
        dismissed.remove(id)
        publishNearby()
    }

    func clearIgnored() {
        for device in ignored { dismissed.remove(device.id) }
        ignored.removeAll()
        publishNearby()
    }

    private func sessionClosed(_ id: String) {
        if let session = sessions.removeValue(forKey: id), session.state.isBusy {
            cancel(session)
        }
    }

    private func refreshReplacementInfo() {
        for session in sessions.values where !session.state.isBusy {
            session.replacing = replacementSummary(for: session.device)
        }
    }

    // MARK: Pairing

    /// A stale pairing for this exact Classic device, which has to go before it
    /// can pair again.
    private func sameAddressEntry(for device: NearbyDevice) -> PairedEntry? {
        guard case .classic = device.source else { return nil }
        return BluetoothSystem.entry(withAddress: device.address)
    }

    /// Other pairings with the same name, e.g. an earlier controller of the same
    /// model, or the same Logitech mouse under an old address (they take a new
    /// address each time they're re-paired).
    private func sameNameEntries(for device: NearbyDevice) -> [PairedEntry] {
        guard replaceSameName else { return [] }
        let ownAddress = device.address.map(BluetoothSystem.normalized)
        return BluetoothSystem.entries(named: device.name)
            .filter { $0.key != ownAddress }
    }

    private func replacementSummary(for device: NearbyDevice) -> String? {
        if let same = sameAddressEntry(for: device) {
            return "Replaces “\(same.displayName)”, which is already paired"
        }
        let others = sameNameEntries(for: device)
        guard let first = others.first else { return nil }
        return others.count == 1
            ? "Replaces the existing “\(first.displayName)” pairing"
            : "Replaces \(others.count) existing “\(first.displayName)” pairings"
    }

    func pair(_ session: PairingSession) {
        guard !session.state.isBusy else { return }
        activePairings += 1
        applyScanning() // inquiry interferes with pairing, so pause while we work

        let device = session.device
        session.warning = nil
        // Same-name pairings are removed only after the new one works, and only
        // those that existed beforehand, so the new pairing is never touched.
        session.oldPairings = Set(sameNameEntries(for: device).map(\.key))
        session.pairedBefore = Set(BluetoothSystem.pairedEntries().map(\.key))

        if let same = sameAddressEntry(for: device) {
            session.state = .working("Removing old pairing for “\(same.displayName)”…")
            BluetoothSystem.unpair([same]) { [weak self, weak session] failed in
                guard let self, let session else { return }
                if !failed.isEmpty { session.warning = BluetoothSystem.replaceWarning(failed) }
                self.startPairing(session)
            }
        } else {
            startPairing(session)
        }
    }

    private func startPairing(_ session: PairingSession) {
        guard sessions[session.id] === session else { return }
        session.state = .working("Pairing…")
        let handle: (PairingEvent) -> Void = { [weak self, weak session] event in
            guard let self, let session else { return }
            switch event {
            case .status(let text): session.state = .working(text)
            case .typeCode(let code): session.state = .typeCode(code)
            case .confirmCode(let code): session.state = .confirmCode(code)
            case .warning(let text): session.warning = text
            case .succeeded, .failed: self.finish(session, with: event)
            }
        }

        switch session.device.source {
        case .classic(let device):
            let pairer = ClassicPairer(device: device, isKeyboard: session.device.kind == .keyboard)
            session.classicPairer = pairer
            pairer.start(onEvent: handle)
        case .lowEnergy(let peripheral):
            if autoConfirmPrompt {
                if !PromptAutoConfirmer.isTrusted { requestAccessibility() }
                promptConfirmer.watch(forDeviceNamed: session.device.name, duration: 45)
            }
            lowEnergy.pair(peripheral, name: session.device.name, onEvent: handle)
        }
    }

    private func finish(_ session: PairingSession, with event: PairingEvent) {
        session.classicPairer = nil
        promptConfirmer.stop()
        switch event {
        case .succeeded:
            session.replacing = nil
            devices[session.id] = nil
            verified.remove(session.id)
            publishNearby()
            removeOldPairings(after: session) { [weak self, weak session] in
                // A popup closed meanwhile was already cleaned up by `cancel`.
                guard let self, let session, self.sessions[session.id] === session else { return }
                session.state = .succeeded
                if session.warning == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.popups.close(session.id) }
                }
                self.activePairings = max(0, self.activePairings - 1)
                self.applyScanning()
            }
            return
        case .failed(let message):
            session.state = .failed(message)
        default:
            break
        }
        activePairings = max(0, activePairings - 1)
        applyScanning()
    }

    /// After a successful pairing, removes the same-named pairings recorded when
    /// Pair was clicked that are now disconnected. The device's previous entry
    /// (if it re-paired under a new address) disconnects once it moves over, so
    /// wait a moment before looking.
    private func removeOldPairings(after session: PairingSession, completion: @escaping () -> Void) {
        guard replaceSameName else { completion(); return }
        session.state = .working("Paired. Checking for old pairings…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak session] in
            guard let session else { completion(); return }
            let entries = BluetoothSystem.pairedEntries()
            // The new pairing's stored name is the device's full name, which is a
            // more precise match than the (possibly shortened) advertised one.
            let newNames = Set(entries.filter { !session.pairedBefore.contains($0.key) }.compactMap { $0.name?.lowercased() })
            let stale = entries.filter { entry in
                guard session.pairedBefore.contains(entry.key), !entry.isConnected else { return false }
                if newNames.isEmpty { return session.oldPairings.contains(entry.key) }
                return entry.name.map { newNames.contains($0.lowercased()) } ?? false
            }
            if !stale.isEmpty { session.state = .working("Paired. Removing \(stale.count) old pairing\(stale.count == 1 ? "" : "s")…") }
            Self.log.notice("Removing \(stale.count) old pairing(s) after pairing \(session.device.displayName, privacy: .public)")
            BluetoothSystem.unpair(stale) { failed in
                if !failed.isEmpty { session.warning = BluetoothSystem.replaceWarning(failed) }
                completion()
            }
        }
    }

    private func cancel(_ session: PairingSession) {
        session.classicPairer?.cancel()
        if case .lowEnergy = session.device.source {
            lowEnergy.cancelPairing()
            promptConfirmer.stop()
        }
        session.classicPairer = nil
        activePairings = max(0, activePairings - 1)
        applyScanning()
    }

    // MARK: Misc

    /// Turning on same-name replacement first explains what it does, since it
    /// drives System Settings on the user's behalf.
    func setReplaceSameName(_ enabled: Bool) {
        guard enabled, !replaceSameName else {
            replaceSameName = enabled
            return
        }
        let alert = NSAlert()
        alert.messageText = "Replace Paired Devices with the Same Name (Experimental)"
        alert.informativeText = """
            When a device pairs, this removes older, disconnected pairings with the same name, for \
            example an old controller of the same model, or the leftover entries some mice (like \
            Logitech's) create each time they re-pair. Your newly paired device and anything that's \
            connected are never removed.

            How it works: macOS doesn't let apps other than Apple's remove Bluetooth pairings. It \
            silently ignores the request. So this app has System Settings do it: it opens \
            Settings › Bluetooth and clicks Show Detail and Forget This Device… for each old entry, \
            just as you would. You'll briefly see the Settings window do this on its own.

            This needs Accessibility access, and a macOS update that changes the Bluetooth pane can \
            stop it from working. If it can't remove something, it tells you what's left.
            """
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        replaceSameName = true
        if !PromptAutoConfirmer.isTrusted { PermissionsWindowController.shared.show() }
    }

    func removeDisconnectedDuplicates() {
        let duplicates = BluetoothSystem.disconnectedDuplicates()
        guard !duplicates.isEmpty, !isRemovingDuplicates else { return }
        isRemovingDuplicates = true
        BluetoothSystem.unpair(duplicates) { [weak self] failed in
            guard let self else { return }
            self.isRemovingDuplicates = false
            self.duplicateCount = BluetoothSystem.disconnectedDuplicates().count
            let alert = NSAlert()
            if failed.isEmpty {
                alert.messageText = "Removed \(duplicates.count) old pairing\(duplicates.count == 1 ? "" : "s")"
            } else {
                alert.alertStyle = .warning
                alert.messageText = "Removed \(duplicates.count - failed.count) of \(duplicates.count) old pairings"
                alert.informativeText = "macOS didn't let the app remove the rest. Remove them in System Settings › Bluetooth."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Bluetooth Settings")
            }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { self.openBluetoothSettings() }
        }
    }

    func requestAccessibility() {
        accessibilityTrusted = PromptAutoConfirmer.requestAccess()
    }

    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login change failed: \(error)")
        }
    }
}
