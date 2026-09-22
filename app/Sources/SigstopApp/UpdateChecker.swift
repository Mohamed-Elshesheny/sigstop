import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateChecker {

    enum State: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case available(version: String)
        case downloading(received: Int64, expected: Int64)
        case extracting(fraction: Double?)
        case readyToInstall(version: String)
        case installing
        case failed(String)
        case unavailable(String)

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

        var offeredVersion: String? {
            switch self {
            case .available(let version), .readyToInstall(let version): return version
            default: return nil
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var updaterIsFree = false
    private var freeObservation: NSKeyValueObservation?

    private var updater: SPUUpdater?
    private var driver: UserDriver?

    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private var cancelInFlight: (() -> Void)?
    private var retryInstall: (() -> Void)?
    private var acknowledge: (() -> Void)?

    private var downloadedBytes: Int64 = 0
    private var expectedBytes: Int64 = 0
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
        updater.automaticallyChecksForUpdates = false

        do {
            try updater.start()
        } catch {
            state = .unavailable("Sparkle would not start, \(error.localizedDescription)")
            return
        }

        driver.owner = self
        self.driver = driver
        self.updater = updater
        updaterIsFree = updater.canCheckForUpdates
        freeObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            Task { @MainActor in self?.updaterIsFree = updater.canCheckForUpdates }
        }
    }

    var canCheck: Bool {
        guard updater != nil else { return false }
        return updaterIsFree && !state.isBusy
    }

    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        resetTransfer()
        state = .checking
        updater.checkForUpdates()
    }

    func proceed() {
        guard let reply = pendingChoice else { return }
        pendingChoice = nil
        reply(.install)
    }

    func retryInstalling() {
        retryInstall?()
    }

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

    fileprivate func didStartUserInitiatedCheck(cancellation: @escaping () -> Void) {
        cancelInFlight = cancellation
        state = .checking
    }

    fileprivate func didFindUpdate(
        version: String,
        alreadyDownloaded: Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        cancelInFlight = nil
        offeredVersion = version
        pendingChoice = reply
        state = alreadyDownloaded ? .readyToInstall(version: version) : .available(version: version)
    }

    fileprivate func didFindInformationOnly(version: String) {
        cancelInFlight = nil
        pendingChoice = nil
        state = .unavailable("\(version) is available but installs by hand. Open the releases page:")
    }

    fileprivate func didFindNothing(error: any Error, acknowledgement: @escaping () -> Void) {
        cancelInFlight = nil
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? Int
        if reason.map({ $0 == SPUNoUpdateFoundReason.onLatestVersion.rawValue }) ?? true {
            state = .upToDate(current: currentVersion)
        } else {
            state = .failed(Self.humanReadable(error))
        }
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

    fileprivate func didStartInstalling(retry: @escaping () -> Void) {
        pendingChoice = nil
        retryInstall = retry
        state = .installing
    }

    fileprivate func didDismiss() {
        pendingChoice = nil
        cancelInFlight = nil
        acknowledge = nil
        if state.isBusy { state = .idle }
    }

    private static func humanReadable(_ error: any Error) -> String {
        let ns = error as NSError
        let parts = [ns.localizedDescription, ns.localizedRecoverySuggestion]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "The update check failed." : parts.joined(separator: " ")
    }
}

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
        owner?.didFindUpdate(
            version: appcastItem.displayVersionString,
            alreadyDownloaded: state.stage != .notDownloaded,
            reply: reply
        )
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
        owner?.didStartInstalling(retry: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        owner?.didDismiss()
    }
}
