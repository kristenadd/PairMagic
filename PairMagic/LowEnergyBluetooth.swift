import CoreBluetooth
import Foundation
import IOBluetooth

/// Scans for Bluetooth LE advertisements and pairs LE devices.
///
/// CoreBluetooth has no "pair" call. Instead we connect and read/subscribe to every
/// characteristic we can see; when the device requires encryption, macOS runs the
/// pairing itself (sometimes showing its own "Connection Request" alert). We detect
/// success by watching the system's paired-device list.
final class LowEnergyScanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onDiscover: ((CBPeripheral, [String: Any], Int) -> Void)?
    var onPoweredChange: ((Bool) -> Void)?

    private var central: CBCentralManager!
    private var wantsToScan = false

    private struct PairingJob {
        let peripheral: CBPeripheral
        let name: String?
        var pairedBefore: Set<String> = []
        var connectedBefore: Set<String> = []
        var isConnected = false
        let onEvent: (PairingEvent) -> Void
        var timer: Timer?

        /// The paired list can still hold a just-forgotten device, which may re-bond
        /// under the same address. So a same-named device that becomes connected
        /// also counts as success, unless it was already connected beforehand.
        func matchesName(_ device: IOBluetoothDevice) -> Bool {
            guard let name, !name.isEmpty else { return false }
            return device.name.map { BluetoothSystem.namesMatch(advertised: name, stored: $0) } ?? false
        }

        mutating func snapshotPairedDevices() {
            let paired = BluetoothSystem.pairedDevices
            pairedBefore = Set(paired.compactMap(\.addressString))
            connectedBefore = Set(paired.filter { matchesName($0) && $0.isConnected() }.compactMap(\.addressString))
        }
    }
    private var job: PairingJob?

    /// Pending test connections, keyed by peripheral.
    private var probes: [UUID: (timer: Timer, completion: (Bool) -> Void)] = [:]

    /// How long a device gets to accept the connection. One that's advertising to
    /// reconnect to a host it was bonded with, rather than in pairing mode, often
    /// never accepts, and CoreBluetooth would otherwise wait forever.
    private let connectTimeout: TimeInterval = 12
    private let pairTimeout: TimeInterval = 45

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        wantsToScan = true
        if central.state == .poweredOn { beginScan() }
    }

    func stop() {
        wantsToScan = false
        if central.state == .poweredOn { central.stopScan() }
    }

    private func beginScan() {
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    // MARK: Probing

    /// Makes a brief test connection and reports whether the device accepted it,
    /// then disconnects. CoreBluetooth hides the advertising flags that say
    /// "pairing mode", and a device advertising only to reconnect to a host it's
    /// bonded with looks identical, but such a device refuses our connection,
    /// whereas one in pairing mode accepts it.
    func probe(_ peripheral: CBPeripheral, timeout: TimeInterval = 6, completion: @escaping (Bool) -> Void) {
        guard probes[peripheral.identifier] == nil, central.state == .poweredOn else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.endProbe(peripheral, accepted: false)
        }
        probes[peripheral.identifier] = (timer, completion)
        central.connect(peripheral)
    }

    private func endProbe(_ peripheral: CBPeripheral, accepted: Bool) {
        guard let probe = probes.removeValue(forKey: peripheral.identifier) else { return }
        probe.timer.invalidate()
        if job?.peripheral != peripheral { central.cancelPeripheralConnection(peripheral) }
        probe.completion(accepted)
    }

    // MARK: Pairing

    func pair(_ peripheral: CBPeripheral, name: String?, onEvent: @escaping (PairingEvent) -> Void) {
        cancelPairing()
        var newJob = PairingJob(peripheral: peripheral, name: name, onEvent: onEvent)
        newJob.snapshotPairedDevices()
        job = newJob
        peripheral.delegate = self
        onEvent(.status("Connecting…"))
        central.connect(peripheral)

        let started = Date()
        job?.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let job = self.job else { return }
            let elapsed = Date().timeIntervalSince(started)
            if !job.isConnected {
                if elapsed >= self.connectTimeout {
                    let device = job.name.map { "“\($0)”" } ?? "The device"
                    self.finish(.failed("\(device) didn't accept a connection, so it's probably not in pairing mode. Put it in pairing mode and try again."), disconnect: true)
                }
                return
            }
            let paired = BluetoothSystem.pairedDevices
            let newlyPaired = paired.contains { !job.pairedBefore.contains($0.addressString ?? "") }
            let reconnected = paired.contains {
                job.matchesName($0) && $0.isConnected() && !job.connectedBefore.contains($0.addressString ?? "")
            }
            if newlyPaired || reconnected {
                self.finish(.succeeded, disconnect: false)
            } else if elapsed >= self.pairTimeout {
                self.finish(.failed("The device didn't finish pairing. Some LE devices can only be paired from System Settings › Bluetooth."), disconnect: true)
            }
        }
    }

    func cancelPairing() {
        finish(nil, disconnect: true)
    }

    private func finish(_ event: PairingEvent?, disconnect: Bool) {
        guard let current = job else { return }
        current.timer?.invalidate()
        job = nil
        if disconnect { central.cancelPeripheralConnection(current.peripheral) }
        if let event { current.onEvent(event) }
    }

    private func beginPairing(_ peripheral: CBPeripheral) {
        guard job?.peripheral == peripheral else { return }
        job?.onEvent(.status("Pairing… (approve any macOS prompt that appears)"))
        peripheral.discoverServices(nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onPoweredChange?(central.state == .poweredOn)
        if central.state == .poweredOn, wantsToScan { beginScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        onDiscover?(peripheral, advertisementData, RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if probes[peripheral.identifier] != nil { endProbe(peripheral, accepted: true) }
        guard job?.peripheral == peripheral else { return }
        job?.isConnected = true
        beginPairing(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if probes[peripheral.identifier] != nil { endProbe(peripheral, accepted: false) }
        guard job?.peripheral == peripheral else { return }
        finish(.failed("Couldn't connect: \(error?.localizedDescription ?? "unknown error")."), disconnect: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Devices often drop the app's connection once the system takes over the
        // HID link, so a disconnect isn't treated as failure; the timer decides.
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Touching protected characteristics is what triggers the system to pair.
        for characteristic in service.characteristics ?? [] {
            if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }
}
