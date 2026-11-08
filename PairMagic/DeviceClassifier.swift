import CoreBluetooth
import Foundation

/// Works out what kind of device something is from its Bluetooth Class of Device
/// (Classic), advertised services (Low Energy) and, as a fallback, its name.
enum DeviceClassifier {
    struct Result {
        var kind: DeviceKind
        var detail: String
        var isInputDevice: Bool
    }

    // MARK: Bluetooth Classic

    static func classify(classOfDevice cod: UInt32, name: String?) -> Result {
        let major = (cod >> 8) & 0x1F
        let minor = (cod >> 2) & 0x3F

        var result: Result
        switch major {
        case 0x05: // Peripheral
            result = classifyPeripheral(minor: minor)
        case 0x04: // Audio/Video
            result = classifyAudio(minor: minor)
        case 0x01: result = Result(kind: .other, detail: "Computer", isInputDevice: false)
        case 0x02: result = Result(kind: .other, detail: "Phone", isInputDevice: false)
        case 0x06: result = Result(kind: .other, detail: "Imaging device", isInputDevice: false)
        case 0x07: result = Result(kind: .other, detail: "Wearable", isInputDevice: false)
        case 0x08: result = Result(kind: .other, detail: "Toy", isInputDevice: false)
        case 0x09: result = Result(kind: .other, detail: "Health device", isInputDevice: false)
        default: result = Result(kind: .other, detail: "Bluetooth device", isInputDevice: false)
        }

        if result.kind == .other, let guess = kind(fromName: name) {
            result.kind = guess
            if result.detail == "Bluetooth device" { result.detail = guess.label }
        }
        return result
    }

    private static func classifyPeripheral(minor: UInt32) -> Result {
        switch minor & 0x0F {
        case 0x01: return Result(kind: .gamepad, detail: "Joystick", isInputDevice: true)
        case 0x02: return Result(kind: .gamepad, detail: "Gamepad", isInputDevice: true)
        case 0x03: return Result(kind: .other, detail: "Remote control", isInputDevice: true)
        case 0x05: return Result(kind: .mouse, detail: "Drawing tablet", isInputDevice: true)
        default: break
        }
        switch minor & 0x30 {
        case 0x10: return Result(kind: .keyboard, detail: "Keyboard", isInputDevice: true)
        case 0x20: return Result(kind: .mouse, detail: "Mouse / pointing device", isInputDevice: true)
        case 0x30: return Result(kind: .keyboard, detail: "Keyboard + pointing device", isInputDevice: true)
        default: return Result(kind: .other, detail: "Input device", isInputDevice: true)
        }
    }

    private static func classifyAudio(minor: UInt32) -> Result {
        switch minor {
        case 0x01: return Result(kind: .headset, detail: "Headset", isInputDevice: false)
        case 0x02: return Result(kind: .headset, detail: "Hands-free headset", isInputDevice: false)
        case 0x04: return Result(kind: .other, detail: "Microphone", isInputDevice: false)
        case 0x05: return Result(kind: .speaker, detail: "Loudspeaker", isInputDevice: false)
        case 0x06: return Result(kind: .headset, detail: "Headphones", isInputDevice: false)
        case 0x07: return Result(kind: .speaker, detail: "Portable audio", isInputDevice: false)
        case 0x08: return Result(kind: .speaker, detail: "Car audio", isInputDevice: false)
        case 0x0A: return Result(kind: .speaker, detail: "HiFi audio", isInputDevice: false)
        default: return Result(kind: .other, detail: "Audio/video device", isInputDevice: false)
        }
    }

    // MARK: Bluetooth Low Energy

    private static let hidService = CBUUID(string: "1812")
    private static let leAudioServices: Set<CBUUID> = [
        CBUUID(string: "184E"), // Audio Stream Control
        CBUUID(string: "1850"), // Published Audio Capabilities
        CBUUID(string: "1853"), // Common Audio
    ]

    /// Returns nil for advertisements that don't look like anything worth pairing
    /// (beacons, phones, trackers, etc.) unless `includeUnknown` is set.
    static func classify(advertisedServices: [CBUUID], name: String?, includeUnknown: Bool) -> Result? {
        let services = Set(advertisedServices)
        let nameGuess = kind(fromName: name)

        if services.contains(hidService) {
            let kind = nameGuess.flatMap { [.keyboard, .mouse, .gamepad].contains($0) ? $0 : nil } ?? .other
            let detail = kind == .other ? "Input device (HID)" : kind.label
            return Result(kind: kind, detail: detail, isInputDevice: true)
        }
        if !services.isDisjoint(with: leAudioServices) {
            return Result(kind: nameGuess ?? .headset, detail: "LE Audio device", isInputDevice: false)
        }
        if includeUnknown, name != nil {
            return Result(kind: nameGuess ?? .other, detail: nameGuess?.label ?? "Bluetooth LE device", isInputDevice: false)
        }
        return nil
    }

    // MARK: Name heuristics

    private static let nameHints: [(DeviceKind, [String])] = [
        (.gamepad, ["controller", "gamepad", "joystick", "xbox", "dualsense", "dualshock", "8bitdo",
                    "joy-con", "joycon", "stadia", "switch pro"]),
        (.keyboard, ["keyboard", "keys", "k380", "k780"]),
        (.mouse, ["mouse", "trackpad", "trackball", "mx master", "mx anywhere", "mx ergo"]),
        (.headset, ["headphone", "headset", "buds", "airpods", "earbuds", "beats", "wh-", "wf-", "quietcomfort"]),
        (.speaker, ["speaker", "soundlink", "boom", "jbl", "sonos", "soundcore"]),
    ]

    static func kind(fromName name: String?) -> DeviceKind? {
        guard let lower = name?.lowercased(), !lower.isEmpty else { return nil }
        for (kind, hints) in nameHints where hints.contains(where: lower.contains) {
            return kind
        }
        return nil
    }
}
