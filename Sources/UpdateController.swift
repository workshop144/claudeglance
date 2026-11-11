import AppKit
import Combine
import Sparkle

/// Owns Sparkle's updater [13]. Starts it only when `UpdatePolicy` allows, and exposes
/// the two things Settings shows: the automatic-check switch and "Check now".
final class UpdateController: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = UpdateController()

    let policy: UpdatePolicy
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController?
    private var observers: Set<AnyCancellable> = []

    private override init() {
        policy = UpdatePolicy.current
        super.init()
    }

    /// Call once at launch.
    func start() {
        guard policy == .enabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        do {
            try updater.start()
        } catch {
            NSLog("ClaudeGlance: updater did not start: \(error.localizedDescription)")
            self.controller = nil
            return
        }
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observers)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyChecks = $0 }
            .store(in: &observers)
    }

    func setAutomaticallyChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    // A menu-bar app has no Dock icon, so a scheduled update alert could open behind
    // other windows. Opt into gentle reminders and bring the app forward to show it.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate && !state.userInitiated {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
