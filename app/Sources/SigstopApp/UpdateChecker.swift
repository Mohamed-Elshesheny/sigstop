import Foundation
import Observation
import Sparkle

/// The app's one network capability, and the whole of it.
///
/// ## Why this exists at all
///
/// Shipping outside the App Store means nobody is told a new build landed, and a break
/// reminder people never update is a break reminder that quietly stops matching their
/// machine. That was true before this file and is still the reason for it.
///
/// ## Why Sparkle rather than a hand-rolled downloader
///
/// The previous version of this file was a `URLSession` GET of the GitHub releases API
/// that read `tag_name` and opened a browser. It was honest but it did not *verify*
/// anything, and the moment an updater downloads and installs rather than pointing at a
/// page, verification is the entire security surface.
///
/// The build is ad-hoc signed. There is no Developer ID and no Team ID, so Apple's code
/// signature proves nothing about who produced an update — Gatekeeper would be checking a
/// signature against nothing. Sparkle closes that with EdDSA: every archive is signed with
/// a private key that lives only in the maintainer's login keychain, the public half is
/// compiled into the app as `SUPublicEDKey`, and Sparkle refuses to install anything whose
/// signature does not verify against it. A compromised GitHub account, a compromised CDN
/// or an attacker on the network can therefore serve a malicious download and still not
/// get it run. That property is worth one dependency, and writing the download-and-verify
/// path by hand to avoid the dependency would have been hand-rolling the one thing nobody
/// should hand-roll.
///
/// ## The shape of the network use, which is the part people will check
///
///   * One URL, compiled in: `SUFeedURL` in Info.plist. A static file on GitHub Pages,
///     byte-identical for everyone, with no query string and nothing to personalise.
///   * It is fetched when the user presses Check for updates. There is no launch check
///     and no timer unless the user switches `automaticallyChecks` on, which is off by
///     default (`SUEnableAutomaticChecks` is `<false/>`).
///   * The request carries no identifier: `SUEnableSystemProfiling` is off, so Sparkle
///     appends no profile parameters, and `userAgentString` below is overridden to a
///     constant that does not even carry the app version.
///   * Nothing is downloaded or installed without a second press.
///
/// What it cannot claim: an HTTP request reveals the client's IP address and the time of
/// the request to whoever serves the file, and no client-side choice changes that.
/// docs/PRIVACY.md §5 states that rather than talking around it.
///
/// CLAUDE.md §4.3 and docs/PRIVACY.md §5 describe exactly this. If this file ever grows a
/// second endpoint, a launch-time check, or anything that sends state upward, both of
/// those documents are wrong and have to be changed first, in their own commit.
@MainActor
@Observable
final class UpdateChecker {

    /// What the About tab draws. One enum, because "is a button enabled" and "is there a
    /// progress bar" must never be able to disagree with each other.
    enum State: Equatable {
        /// Nothing has happened yet, or the last thing that happened was dismissed.
        case idle
        case checking
        case upToDate(current: String)
        /// A newer version exists and the user has not yet said to fetch it.
        case available(version: String)
        /// `received` and `expected` are bytes. `expected` is 0 when the server did not
        /// send a content length, which is a real case and renders as indeterminate.
        case downloading(received: Int64, expected: Int64)
        /// Unpacking. 0…1, or `nil` before Sparkle reports the first progress.
        case extracting(fraction: Double?)
        /// Downloaded, verified, and waiting for the user to agree to relaunch.
        case readyToInstall(version: String)
        case installing
        case failed(String)
        /// Sparkle cannot run here at all — `swift run` with no `.app` around it, or the
        /// updater refused to start. Distinct from `.failed` because no button the user
        /// presses will fix it.
        case unavailable(String)

        /// Download fraction, or `nil` when the length is unknown.
        var downloadFraction: Double? {
            guard case .downloading(let received, let expected) = self, expected > 0 else { return nil }
            return min(1, max(0, Double(received) / Double(expected)))
        }

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .extracting, .installing: return true
            default: return false
            }
        }

        /// The version the user is being offered, if they are being offered one.
        ///
        /// Exists so the menu bar dropdown can mention an update without duplicating the
        /// state machine. It matters most for a check the user did not initiate: with a
        /// custom user driver, a scheduled background check has no window of its own, so
        /// without this the only way to learn about it would be to happen to open
        /// Settings. Automatic checks are opt-in, but somebody who opted in expects to be
        /// told.
        var offeredVersion: String? {
            switch self {
            case .available(let version), .readyToInstall(let version): return version
            default: return nil
            }
        }
    }

    private(set) var state: State = .idle

    private var updater: SPUUpdater?
    private var driver: UserDriver?

    /// Sparkle hands progress and decisions to the driver as escaping blocks. Whichever
    /// one is outstanding is parked here until the user presses something.
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private var cancelInFlight: (() -> Void)?
    private var acknowledge: (() -> Void)?

    private var downloadedBytes: Int64 = 0
    private var expectedBytes: Int64 = 0
    /// Remembered from `showUpdateFound` so the ready-to-install state can name a version;
    /// Sparkle does not repeat it later in the sequence.
    private var offeredVersion: String?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    init() {
        guard AppPaths.isBundled else {
            state = .unavailable("Updating needs the bundled app. Build it with `make bundle`.")
            return
        }

        let driver = UserDriver()
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )

        updater.userAgentString = "sigstop"
        updater.sendsSystemProfile = false
        updater.automaticallyDownloadsUpdates = false

        do {
            try updater.start()
        } catch {
            state = .unavailable("Sparkle would not start — \(error.localizedDescription)")
            return
        }

        driver.owner = self
        self.driver = driver
        self.updater = updater
    }

    // MARK: - What the UI calls

    var canCheck: Bool {
        guard let updater else { return false }
        return updater.canCheckForUpdates && !state.isBusy
    }

    /// Whether Sparkle may check on its own schedule.
    ///
    /// This one setting lives in Sparkle's own `UserDefaults` rather than in
    /// `settings.json` with everything else, and that is not an oversight: Sparkle's
    /// scheduler reads the default directly, there is no supported way to feed it from a
    /// file, and a copy in `settings.json` that the scheduler ignored would be a switch
    /// that lies. docs/PRIVACY.md §5.3 notes the exception.
    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// The only entry point that starts a network request. Called from a button and from
    /// nowhere else — no `onAppear`, no timer, no launch path.
    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        resetTransfer()
        state = .checking
        updater.checkForUpdates()
    }

    /// Agree to whatever Sparkle is currently asking: download the offered update, or
    /// install the one that is ready.
    func proceed() {
        guard let reply = pendingChoice else { return }
        pendingChoice = nil
        reply(.install)
    }

    /// Back out of the current step. Cancels an in-flight transfer if there is one.
    func dismiss() {
        if let cancel = cancelInFlight {
            cancelInFlight = nil
            cancel()
        }
        if let reply = pendingChoice {
            pendingChoice = nil
            reply(.dismiss)
        }
        if let ack = acknowledge {
            acknowledge = nil
            ack()
        }
        if state.isBusy || isOffering { state = .idle }
    }

    private var isOffering: Bool {
        switch state {
        case .available, .readyToInstall, .failed: return true
        default: return false
        }
    }

    private func resetTransfer() {
        downloadedBytes = 0
        expectedBytes = 0
        offeredVersion = nil
    }

    // MARK: - Callbacks from the user driver

    fileprivate func didStartUserInitiatedCheck(cancellation: @escaping () -> Void) {
        cancelInFlight = cancellation
        state = .checking
    }

    fileprivate func didFindUpdate(version: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancelInFlight = nil
        offeredVersion = version
        pendingChoice = reply
        state = .available(version: version)
    }

    fileprivate func didFindInformationOnly(version: String) {
        cancelInFlight = nil
        pendingChoice = nil
        state = .failed("\(version) exists but has to be installed by hand. Open Releases below.")
    }

    fileprivate func didFindNothing(error: any Error, acknowledgement: @escaping () -> Void) {
        cancelInFlight = nil
        state = .upToDate(current: currentVersion)
        acknowledgement()
    }

    fileprivate func didFail(error: any Error, acknowledgement: @escaping () -> Void) {
        cancelInFlight = nil
        pendingChoice = nil
        state = .failed(Self.humanReadable(error))
        acknowledgement()
    }

    fileprivate func didStartDownload(cancellation: @escaping () -> Void) {
        cancelInFlight = cancellation
        pendingChoice = nil
        downloadedBytes = 0
        state = .downloading(received: 0, expected: expectedBytes)
    }

    fileprivate func didLearnContentLength(_ length: UInt64) {
        expectedBytes = Int64(clamping: length)
        state = .downloading(received: downloadedBytes, expected: expectedBytes)
    }

    fileprivate func didReceive(bytes: UInt64) {
        downloadedBytes += Int64(clamping: bytes)
        state = .downloading(received: downloadedBytes, expected: expectedBytes)
    }

    fileprivate func didStartExtracting() {
        cancelInFlight = nil
        state = .extracting(fraction: nil)
    }

    fileprivate func didExtract(fraction: Double) {
        state = .extracting(fraction: min(1, max(0, fraction)))
    }

    fileprivate func readyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingChoice = reply
        state = .readyToInstall(version: offeredVersion ?? "the new version")
    }

    fileprivate func didStartInstalling() {
        pendingChoice = nil
        state = .installing
    }

    fileprivate func didDismiss() {
        pendingChoice = nil
        cancelInFlight = nil
        acknowledge = nil
        if state.isBusy { state = .idle }
    }

    /// Sparkle's errors are `NSError`s with a useful recovery suggestion hanging off the
    /// user info, and a `localizedDescription` that is often just "An error occurred."
    /// Preferring the suggestion is the difference between a message and a shrug.
    private static func humanReadable(_ error: any Error) -> String {
        let ns = error as NSError
        let parts = [ns.localizedDescription, ns.localizedRecoverySuggestion]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "The update check failed." : parts.joined(separator: " ")
    }
}

// MARK: - The driver

/// Sparkle's `SPUUserDriver` is an Objective-C protocol, so this has to be an `NSObject`
/// and cannot be the `@Observable` model itself. It holds no state and makes no decisions:
/// every method forwards to `UpdateChecker`, which is where the state machine lives.
///
/// `owner` is `weak` and `unowned(unsafe)`-free on purpose — Sparkle retains its driver for
/// the process lifetime, and a strong reference back would retain the model with it.
@MainActor
private final class UserDriver: NSObject, SPUUserDriver {
    weak var owner: UpdateChecker?

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner?.didStartUserInitiatedCheck(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard !appcastItem.isInformationOnlyUpdate else {
            reply(.dismiss)
            owner?.didFindInformationOnly(version: appcastItem.displayVersionString)
            return
        }
        owner?.didFindUpdate(version: appcastItem.displayVersionString, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.didFindNothing(error: error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.didFail(error: error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        owner?.didStartDownload(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        owner?.didLearnContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        owner?.didReceive(bytes: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        owner?.didStartExtracting()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        owner?.didExtract(fraction: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        owner?.readyToInstall(reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        owner?.didStartInstalling()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        owner?.didDismiss()
    }
}
