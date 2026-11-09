import AppKit
import Combine
import Sparkle

/// Checks for and installs updates with Sparkle. The feed URL, signing key and check interval are
/// in Info.plist; releases (and their signed appcast.xml) come from the GitHub release workflow.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    /// False while a check or install is already in progress.
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecks = false {
        didSet {
            if updater.automaticallyChecksForUpdates != automaticallyChecks {
                updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }

    private var controller: SPUStandardUpdaterController!
    private var updater: SPUUpdater { controller.updater }
    private var observers: Set<AnyCancellable> = []
    private var started = false

    private override init() {
        super.init()
        // Debug builds don't check on their own: they'd always find the latest release
        // newer than themselves. (Not via automaticallyChecksForUpdates, which is stored
        // in preferences shared with the installed app.)
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: start, updaterDelegate: nil, userDriverDelegate: self)
        started = start
        automaticallyChecks = updater.automaticallyChecksForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                guard let self else { return }
                // An updater that hasn't started yet reports false, but checking starts it.
                self.canCheckForUpdates = canCheck || !self.started
            }
            .store(in: &observers)
    }

    func checkForUpdates() {
        if !started { controller.startUpdater(); started = true }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    // PairMagic has no Dock icon or main window, so Sparkle asks how to present updates found by
    // the daily background check. We still show Sparkle's update window, but bring it forward so it
    // doesn't open behind other apps.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }
}
