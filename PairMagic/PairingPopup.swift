import AppKit
import SwiftUI

/// Borderless panels can't become key by default, which would disable the
/// Return / Escape shortcuts on the popup's buttons.
private final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Floating, non-activating panels stacked in the top-right corner of the screen,
/// one per device that's ready to pair.
final class PopupManager {
    var onClose: ((String) -> Void)?

    private var panels: [(id: String, panel: NSPanel)] = []
    private var resizeObservers: [String: NSObjectProtocol] = [:]

    func show(_ session: PairingSession, coordinator: PairingCoordinator) {
        let view = PairingPopupView(session: session, coordinator: coordinator)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]

        // Borderless, so the window is exactly the size of the SwiftUI content; the
        // view draws its own rounded background.
        let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panels.append((session.id, panel))
        resizeObservers[session.id] = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.layout() }

        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func bringToFront(_ id: String) {
        panels.first { $0.id == id }?.panel.orderFrontRegardless()
    }

    func close(_ id: String) {
        guard let index = panels.firstIndex(where: { $0.id == id }) else { return }
        let panel = panels.remove(at: index).panel
        if let observer = resizeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            panel.orderOut(nil)
        }
        onClose?(id)
        layout()
    }

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var top = visible.maxY - 10
        for (_, panel) in panels {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 10, y: top - size.height))
            top -= size.height + 10
        }
    }
}

struct PairingPopupView: View {
    @ObservedObject var session: PairingSession
    let coordinator: PairingCoordinator

    private var device: NearbyDevice { session.device }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                DeviceIcon(kind: device.kind, succeeded: session.state == .succeeded)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(device.displayName)
                        .font(.headline)
                        .lineLimit(2)
                    Text(device.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let address = device.address {
                        Text(address)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let replacing = session.replacing, session.state != .succeeded {
                Label(replacing, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            status

            if let warning = session.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if case .failed = session.state {
                    Button("Bluetooth Settings…") { coordinator.openBluetoothSettings() }
                }
                Spacer()
                if session.state.isBusy {
                    Button("Cancel") { coordinator.dismiss(session) }
                        .keyboardShortcut(.cancelAction)
                } else if session.state != .succeeded {
                    Button("Not Now") { coordinator.dismiss(session) }
                        .keyboardShortcut(.cancelAction)
                        .help("Hide until this device next goes into pairing mode")
                    Button("Ignore") { coordinator.ignore(session) }
                        .help("Never ask about this device again. Undo from the menu bar under Ignored Devices.")
                }
                primaryButton
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
    }

    private var headline: String {
        switch session.state {
        case .succeeded: return "Paired"
        case .failed: return "Pairing failed"
        default: return "\(device.kind.label) ready to pair"
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch session.state {
        case .ready:
            Button(session.replacing == nil ? "Pair" : "Replace & Pair") { coordinator.pair(session) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .failed:
            Button("Try Again") { coordinator.pair(session) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .succeeded:
            Button("Done") { coordinator.dismiss(session) }
                .keyboardShortcut(.defaultAction)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var status: some View {
        switch session.state {
        case .ready:
            EmptyView()
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout)
            }
        case .typeCode(let code):
            VStack(alignment: .leading, spacing: 4) {
                Text("Type this code on the keyboard, then press Return:").font(.callout)
                Text(code).font(.system(size: 28, weight: .semibold, design: .monospaced)).kerning(4)
            }
        case .confirmCode(let code):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Confirming code \(code)…").font(.callout)
            }
        case .succeeded:
            Label("\(device.displayName) is paired and ready to use.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DeviceIcon: View {
    let kind: DeviceKind
    var succeeded = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 60, height: 60)
                .overlay(
                    Image(systemName: kind.symbol)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                )
            if succeeded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white, .green)
                    .offset(x: 6, y: 6)
            }
        }
    }
}
