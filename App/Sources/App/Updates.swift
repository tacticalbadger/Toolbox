import AppKit
import Sparkle

/// Over-the-air updates, through Sparkle.
///
/// Once a day, and when asked from the menu, the app reads a feed
/// (`SUFeedURL` in the Info.plist: a file attached to the newest GitHub
/// Release). What it finds there is offered with its release notes and
/// installed when the user agrees; quitting to install goes through the
/// app's own "N sessions will be disconnected" question like any other
/// quit.
///
/// Nothing is taken on the feed's word. The feed and the archive both have
/// to carry a signature made with the update key whose public half is in
/// the Info.plist (`SUPublicEDKey`, `SURequireSignedFeed`,
/// `SUVerifyUpdateBeforeExtraction`), so whoever controls the place the
/// files are served from can withhold an update but not supply one.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?
    /// A feed named on the command line (`--updater-feed <url>`), for the
    /// update rehearsal.
    private var rehearsalFeed: String?

    /// Starts the updater, unless this run has no business looking for
    /// updates.
    func start() {
        // A run against a store named in the environment is a test run. It
        // must not find the real release and offer to replace a test copy
        // with it; the rehearsal names a feed of its own instead. The
        // everyday app takes no feed from the command line.
        let args = CommandLine.arguments
        if !AppModel.shared.usesDefaultStore {
            rehearsalFeed = args.firstIndex(of: "--updater-feed").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard AppModel.shared.usesDefaultStore || rehearsalFeed != nil else { return }
        // A bundle made without the feed address and the key (the Xcode
        // project's debug build can be one) has nothing to check against.
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] is String, info["SUPublicEDKey"] is String else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// Whether this run looks for updates at all.
    var isActive: Bool { controller != nil }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// The daily check. On unless the user switches it off.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Toolbox ▸ Check for Updates…: looks now and says what it found.
    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    /// Looks now the way the daily check does: nothing is shown unless
    /// there is an update (`--demo-update`).
    func checkInBackground() {
        controller?.updater.checkForUpdatesInBackground()
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        rehearsalFeed
    }

    // The rest only writes down what happened, one `updates:` line each.
    // The rehearsal reads them, and so can anyone looking at Console.

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("updates: found \(item.displayVersionString) (\(item.versionString))")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        NSLog("updates: downloaded \(item.displayVersionString)")
    }

    // (Sparkle's "did extract" callback is not logged: it arrives as soon
    // as the archive is handed to the installer, before the signature has
    // been checked or anything unpacked.)

    /// The archive's signature held, it was unpacked and what came out was
    /// checked: all that is left is to swap the bundles once the app is
    /// gone.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        NSLog("updates: \(item.displayVersionString) is verified and will be installed when the app quits")
        return false
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        NSLog("updates: installing \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        NSLog("updates: stopped: could not download \(item.displayVersionString): \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain, error.code == Int(SUError.noUpdateError.rawValue) {
            NSLog("updates: nothing newer in the feed")
        } else {
            NSLog("updates: stopped: \(error.localizedDescription) (\(error.domain) \(error.code))")
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        NSLog("updates: done")
    }
}
