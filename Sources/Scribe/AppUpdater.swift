import AppKit
import Sparkle

/// Checks GitHub for new releases and installs them, using Sparkle.
///
/// The feed is `appcast.xml`, uploaded with every release, so
/// `releases/latest/download/appcast.xml` always describes the newest version.
/// An update installs only if its EdDSA signature matches the key in
/// Info.plist and it is signed by the same Developer ID as this build.
@MainActor
final class AppUpdater: ObservableObject {

    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private let delegate = UpdaterDelegate()

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: delegate,
                                                  userDriverDelegate: nil)
        // `--install-update-now` checks, downloads and installs without any
        // window. It exists to test the whole update path end to end.
        if CommandLine.arguments.contains("--install-update-now") {
            delegate.installImmediately = true
            controller.updater.automaticallyDownloadsUpdates = true
            controller.updater.checkForUpdatesInBackground()
        }
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func checkForUpdates() {
        // A menu bar app is never frontmost, so the update window would open
        // behind whatever the user is looking at.
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

/// Logs what the updater does, so a failed update leaves a trace in Scribe's log.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {

    var installImmediately = false

    /// `--update-feed <url>` points the updater at another appcast, for testing.
    func feedURLString(for updater: SPUUpdater) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--update-feed"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.info("update available: \(item.displayVersionString) (build \(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.info("update check: up to date")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Log.error("update failed: \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        Log.info("update \(item.displayVersionString) downloaded and verified")
        if installImmediately {
            immediateInstallationBlock()
            return true
        }
        return false
    }
}
