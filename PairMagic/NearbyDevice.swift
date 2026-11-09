import CoreBluetooth
import Foundation
import IOBluetooth

enum DeviceKind: String, Codable {
    case keyboard, mouse, gamepad, headset, speaker, other

    var symbol: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .gamepad: return "gamecontroller"
        case .headset: return "headphones"
        case .speaker: return "hifispeaker"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    var label: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        case .gamepad: return "Game Controller"
        case .headset: return "Headset"
        case .speaker: return "Speaker"
        case .other: return "Bluetooth Device"
        }
    }
}

/// The device types the user can choose to be offered, under Device Types in the
/// menu. `.other` (phones, computers, wearables, ...) is only offered with
/// "Show All Device Types" on, so it isn't one of the choices.
enum DeviceCategory: String, CaseIterable, Identifiable {
    case keyboard, mouse, gamepad, headset, speaker, otherInput, other

    static let choices: [DeviceCategory] = [.keyboard, .mouse, .gamepad, .headset, .speaker, .otherInput]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keyboard: return "Keyboards"
        case .mouse: return "Mice & Trackpads"
        case .gamepad: return "Game Controllers"
        case .headset: return "Headsets & Headphones"
        case .speaker: return "Speakers"
        case .otherInput: return "Other Input Devices"
        case .other: return "Other Devices"
        }
    }

    var symbol: String {
        switch self {
        case .keyboard: return DeviceKind.keyboard.symbol
        case .mouse: return DeviceKind.mouse.symbol
        case .gamepad: return DeviceKind.gamepad.symbol
        case .headset: return DeviceKind.headset.symbol
        case .speaker: return DeviceKind.speaker.symbol
        case .otherInput: return "appletvremote.gen4"
        case .other: return DeviceKind.other.symbol
        }
    }
}

enum DeviceSource {
    case classic(IOBluetoothDevice)
    case lowEnergy(CBPeripheral)
}

struct NearbyDevice {
    let id: String
    let source: DeviceSource
    var name: String?
    var kind: DeviceKind
    /// Human readable detail, e.g. "Keyboard + pointing device".
    var detail: String
    /// True for devices that advertise as an input (HID) device.
    var isInputDevice: Bool
    var rssi: Int?
    var lastSeen: Date

    /// False until the device has told us its name (LE names often arrive in a
    /// later packet, and some devices never send one).
    var hasName: Bool { !(name ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    var displayName: String {
        if hasName, let name { return name }
        if let address { return "Unnamed \(kind.label) (\(address))" }
        return "Unnamed \(kind.label)"
    }

    var transportName: String {
        switch source {
        case .classic: return "Bluetooth Classic"
        case .lowEnergy: return "Bluetooth Low Energy"
        }
    }

    var address: String? {
        if case .classic(let device) = source { return device.addressString }
        return nil
    }

    /// Signal strength (dBm) from which a device counts as right next to the Mac,
    /// roughly within a metre or two.
    static let strongSignal = -60

    /// The RSSI, if the radio reported a real reading (127 means "not available").
    private var validRSSI: Int? {
        guard let rssi, rssi < 0, rssi > -127 else { return nil }
        return rssi
    }

    /// True when the signal is strong, so the device is probably the one in the
    /// user's hand rather than a neighbour's. Unknown strength counts as nearby,
    /// so a device that doesn't report RSSI can still pop up.
    var isNearby: Bool {
        guard let rssi = validRSSI else { return true }
        return rssi >= Self.strongSignal
    }

    var signalDescription: String? {
        guard let rssi = validRSSI else { return nil }
        switch rssi {
        case Self.strongSignal...: return "Strong signal"
        case (-75)...: return "Good signal"
        default: return "Weak signal"
        }
    }

    var summary: String {
        [detail, transportName, signalDescription].compactMap { $0 }.joined(separator: " · ")
    }

    var category: DeviceCategory {
        switch kind {
        case .keyboard: return .keyboard
        case .mouse: return .mouse
        case .gamepad: return .gamepad
        case .headset: return .headset
        case .speaker: return .speaker
        case .other: return isInputDevice ? .otherInput : .other
        }
    }
}
