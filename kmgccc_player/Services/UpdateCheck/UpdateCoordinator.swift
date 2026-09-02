//
//  UpdateCoordinator.swift
//  myPlayer2
//

import AppKit
import Combine
import Sparkle

private final class UpdateCallbackBox: @unchecked Sendable {
    private let callback: () -> Void

    init(_ callback: @escaping () -> Void) {
        self.callback = callback
    }

    func call() {
        callback()
    }
}

enum UpdateFailureStage {
    case configuration
    case download
    case preparation
    case installation
    case relaunch
    case termination
}

struct UpdateFailure {
    let stage: UpdateFailureStage
    let title: String
    let message: String
    let metadata: UpdateReadyMetadata?
}

enum UpdateCoordinatorState {
    case idle
    case checking(manual: Bool)
    case downloading(progress: Double?)
    case preparing(progress: Double?)
    case ready(UpdateReadyMetadata)
    case installReplyPending(UpdateReadyMetadata)
    case waitingForTermination(UpdateReadyMetadata?, retryInFlight: Bool)
    case installing
    case failed(UpdateFailure)
    case suppressed(build: String)
}

@MainActor
final class UpdateCoordinator: NSObject, ObservableObject {
    static let shared = UpdateCoordinator()

    @Published private(set) var state: UpdateCoordinatorState = .idle
    @Published private(set) var automaticUpdatesEnabled: Bool

    /// Installed by AppSessionHost. The callback must finish all local shutdown
    /// work and then invoke its completion so Sparkle can safely relaunch.
    var terminationPreparationHandler: ((@escaping @MainActor () -> Void) -> Void)?
    var installationDidAbortHandler: (() -> Void)?

    private enum CheckKind {
        case automatic
        case manual
    }

    private lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: self,
        delegate: self
    )

    private let environment: UpdateEnvironment?
    private let environmentError: Error?
    private var hasStarted = false
    private var checkKind: CheckKind = .automatic
    private var activeFeedURL: URL?
    private var attemptedFallback = false
    private var shouldRetryUsingFallback = false
    private var pendingPrimaryError: Error?

    private var currentItem: SUAppcastItem?
    private var checkCancellation: (() -> Void)?
    private var downloadCancellation: (() -> Void)?
    private var readyChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyMetadata: UpdateReadyMetadata?
    private var retryTerminationHandler: (() -> Void)?
    private var retryTerminationInFlight = false
    private var retryTerminationGeneration = 0
    private var retryTerminationTimer: Timer?
    private var fallbackRetryTimer: Timer?
    private var fallbackRetryAttempts = 0
    private var checkTimeoutTimer: Timer?
    private var checkGeneration = 0
    private var expectedDownloadLength: UInt64 = 0
    private var receivedDownloadLength: UInt64 = 0
    private var expiryTimer: Timer?
    private var activeObserver: NSObjectProtocol?

    private override init() {
        UpdatePreferences.migrateIfNeeded()
        automaticUpdatesEnabled = UpdatePreferences.automaticUpdatesEnabled()

        do {
            environment = try UpdateEnvironment.resolve(info: Bundle.main.infoDictionary ?? [:])
            environmentError = nil
        } catch {
            environment = nil
            environmentError = error
        }

        let storedMetadata = UpdatePreferences.readyMetadata()
        let installedBuild = Bundle.main.object(
            forInfoDictionaryKey: kCFBundleVersionKey as String
        ) as? String
        if let storedMetadata,
           UpdateBuildPolicy.isAlreadyInstalled(
               metadata: storedMetadata,
               installedBuild: installedBuild
           ) {
            readyMetadata = nil
            UpdatePreferences.setReadyMetadata(nil)
        } else {
            readyMetadata = storedMetadata
        }
        super.init()

        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.expireReadyUpdateIfNeeded()
            }
        }
    }

    var readyUpdate: UpdateReadyMetadata? {
        guard case .ready(let metadata) = state else { return nil }
        return metadata
    }

    var canCheckForUpdates: Bool {
        hasStarted && updater.canCheckForUpdates
    }

    var canCancelCurrentOperation: Bool {
        if checkCancellation != nil || downloadCancellation != nil || fallbackRetryTimer != nil {
            return true
        }
        if case .checking = state {
            return true
        }
        return false
    }

    var isInstallReplyPending: Bool {
        if case .installReplyPending = state { return true }
        return false
    }

    func startAutomaticUpdatesIfNeeded() {
        guard startUpdaterIfNeeded() else { return }
        expireReadyUpdateIfNeeded()

        guard !isCheckInFlight else { return }

        guard automaticUpdatesEnabled else {
            Log.debug("[UpdateCoordinator] Automatic updates are disabled", category: .ui)
            return
        }

        beginCheck(.automatic, useFallback: false)
    }

    func checkManually() {
        guard startUpdaterIfNeeded() else { return }
        expireReadyUpdateIfNeeded()

        guard !isCheckInFlight else {
            showAlert(
                title: "正在处理更新",
                message: "当前更新任务尚未结束，请稍后再试。"
            )
            return
        }

        beginCheck(.manual, useFallback: false)
    }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        guard automaticUpdatesEnabled != enabled else { return }
        automaticUpdatesEnabled = enabled
        UpdatePreferences.setAutomaticUpdatesEnabled(enabled)

        guard startUpdaterIfNeeded() else { return }
        updater.automaticallyChecksForUpdates = enabled
        // The custom user driver performs silent downloads while retaining a
        // cancellable ready-to-install reply. Sparkle still owns the package.
        updater.automaticallyDownloadsUpdates = false

        if enabled {
            guard !isCheckInFlight else { return }
            beginCheck(.automatic, useFallback: false)
        } else {
            cancelCurrentUpdate(markSuppressed: false)
            updater.resetUpdateCycle()
        }
    }

    func restartAndInstall() {
        guard let metadata = readyMetadata, let readyChoiceReply else { return }
        self.readyChoiceReply = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        state = .installReplyPending(metadata)

        let replyBox = UpdateCallbackBox {
            readyChoiceReply(.install)
        }
        let install: @MainActor @Sendable () -> Void = { [weak self] in
            self?.state = .installing
            replyBox.call()
        }
        if let terminationPreparationHandler {
            terminationPreparationHandler(install)
        } else {
            install()
        }
    }

    func retryTerminatingApplication() {
        guard let retryTerminationHandler, !retryTerminationInFlight else { return }
        retryTerminationInFlight = true
        let generation = retryTerminationGeneration
        state = .waitingForTermination(readyMetadata, retryInFlight: true)
        retryTerminationHandler()
        retryTerminationTimer?.invalidate()
        retryTerminationTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.retryTerminationGeneration else { return }
                self.clearTerminationRetry()
                self.state = .failed(
                    UpdateFailure(
                        stage: .termination,
                        title: "无法退出并更新",
                        message: "应用未能及时退出。请关闭正在进行的操作后重新检查更新。",
                        metadata: self.readyMetadata
                    )
                )
                self.installationDidAbortHandler?()
            }
        }
    }

    func dismissReadyUpdate() {
        cancelCurrentUpdate(markSuppressed: true)
    }

    func cancelCurrentOperation() {
        guard canCancelCurrentOperation else { return }
        cancelCurrentUpdate(markSuppressed: false)
        updater.resetUpdateCycle()
    }

    func retryFailedUpdate() {
        guard case .failed = state else { return }
        checkManually()
    }

    func dismissFailure() {
        guard case .failed = state else { return }
        state = .idle
    }

    func handleApplicationWillTerminate() {
        // Sparkle automatically installs a prepared update when the host exits.
        // Do not answer the ready callback here: doing so can turn an ordinary
        // quit into a second explicit termination request.
        expiryTimer?.invalidate()
    }

    private func startUpdaterIfNeeded() -> Bool {
        if hasStarted { return true }
        guard environment != nil else {
            let message = environmentError?.localizedDescription
                ?? "Update configuration is unavailable."
            state = .failed(UpdateFailure(stage: .configuration, title: "更新配置不可用", message: message, metadata: nil))
            Log.error("[UpdateCoordinator] Refusing to start: \(message)", category: .ui)
            return false
        }

        activeFeedURL = environment?.primaryFeedURL
        updater.sendsSystemProfile = false
        updater.automaticallyChecksForUpdates = automaticUpdatesEnabled
        updater.automaticallyDownloadsUpdates = false

        do {
            try updater.start()
            hasStarted = true
            scheduleExpiryTimer()
            Log.info("[UpdateCoordinator] Sparkle updater started", category: .ui)
            return true
        } catch {
            state = .failed(UpdateFailure(stage: .configuration, title: "更新启动失败", message: error.localizedDescription, metadata: nil))
            Log.error("[UpdateCoordinator] Failed to start Sparkle: \(error)", category: .ui)
            return false
        }
    }

    private var isCheckInFlight: Bool {
        if fallbackRetryTimer != nil {
            return true
        }
        if case .checking = state {
            return true
        }
        return false
    }

    private func beginCheck(_ kind: CheckKind, useFallback: Bool) {
        guard hasStarted, let environment else { return }
        guard updater.canCheckForUpdates else {
            if kind == .manual {
                showAlert(
                    title: "正在处理更新",
                    message: "当前更新任务尚未结束，请稍后再试。"
                )
            }
            return
        }

        checkKind = kind
        activeFeedURL = useFallback
            ? environment.fallbackFeedURL
            : environment.primaryFeedURL
        if !useFallback {
            attemptedFallback = false
            pendingPrimaryError = nil
        }
        shouldRetryUsingFallback = false
        checkGeneration += 1
        invalidateCheckRecoveryTimers()
        state = .checking(manual: kind == .manual)
        scheduleCheckTimeout()

        switch kind {
        case .automatic:
            updater.checkForUpdatesInBackground()
        case .manual:
            updater.checkForUpdates()
        }
    }

    private func cancelCurrentUpdate(markSuppressed: Bool) {
        let build = readyMetadata?.build ?? currentItem?.versionString

        readyChoiceReply?(.skip)
        readyChoiceReply = nil
        downloadCancellation?()
        downloadCancellation = nil
        checkCancellation?()
        checkCancellation = nil

        checkGeneration += 1
        invalidateCheckRecoveryTimers()
        shouldRetryUsingFallback = false
        pendingPrimaryError = nil
        attemptedFallback = false

        readyMetadata = nil
        UpdatePreferences.setReadyMetadata(nil)
        expiryTimer?.invalidate()
        expiryTimer = nil

        if markSuppressed, let build {
            UpdatePreferences.setSuppressedBuild(build)
            state = .suppressed(build: build)
        } else {
            state = .idle
        }
    }

    private func markReady(item: SUAppcastItem) {
        let metadata = UpdateReadyMetadata(
            version: item.displayVersionString,
            build: item.versionString,
            readyAt: Date()
        )
        readyMetadata = metadata
        UpdatePreferences.setReadyMetadata(metadata)
        state = .ready(metadata)
        scheduleExpiryTimer()
    }

    private func expireReadyUpdateIfNeeded(now: Date = Date()) {
        guard let metadata = readyMetadata ?? UpdatePreferences.readyMetadata(),
              metadata.isExpired(at: now) else {
            return
        }

        readyMetadata = metadata
        cancelCurrentUpdate(markSuppressed: true)
        Log.info(
            "[UpdateCoordinator] Removed expired prepared update build \(metadata.build)",
            category: .ui
        )
    }

    private func scheduleExpiryTimer() {
        expiryTimer?.invalidate()
        guard let metadata = readyMetadata else { return }

        expiryTimer = Timer.scheduledTimer(
            withTimeInterval: max(1, metadata.expiresAt.timeIntervalSinceNow),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.expireReadyUpdateIfNeeded()
            }
        }
    }

    private func shouldSuppress(_ item: SUAppcastItem, userInitiated: Bool) -> Bool {
        let suppressedBuild = UpdatePreferences.suppressedBuild()
        if UpdateBuildPolicy.shouldClearSuppression(
            candidateBuild: item.versionString,
            suppressedBuild: suppressedBuild
        ) {
            UpdatePreferences.setSuppressedBuild(nil)
            return false
        }

        if userInitiated {
            return false
        }

        return UpdateBuildPolicy.isSuppressed(
            candidateBuild: item.versionString,
            suppressedBuild: suppressedBuild
        )
    }

    private func showManualUpdatePrompt(
        item: SUAppcastItem,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 \(item.displayVersionString)"
        alert.informativeText = "点击后将在后台安全下载。完成后可从侧边栏一键重启更新。"
        alert.addButton(withTitle: "下载更新")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            UpdatePreferences.setSuppressedBuild(nil)
            state = .downloading(progress: nil)
            reply(.install)
        } else {
            state = .idle
            reply(.dismiss)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func scheduleFallbackIfNeeded(error: Error) {
        guard let environment,
              UpdateFallbackPolicy.shouldUseFallback(for: error),
              activeFeedURL == environment.primaryFeedURL,
              !attemptedFallback else {
            return
        }
        pendingPrimaryError = error
        shouldRetryUsingFallback = true
    }

    private func scheduleCheckTimeout() {
        checkTimeoutTimer?.invalidate()
        let generation = checkGeneration
        checkTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: UpdateCheckRecoveryPolicy.checkTimeout,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.checkGeneration == generation else { return }
                self.handleCheckTimeout()
            }
        }
    }

    private func handleCheckTimeout() {
        guard case .checking = state else { return }

        checkCancellation?()
        checkCancellation = nil
        updater.resetUpdateCycle()

        let error = NSError(
            domain: "KMGUpdateCoordinator",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "检查更新超时，请检查网络连接后重试。"
            ]
        )
        finishUpdateCheckWithFailure(error)
    }

    private func scheduleFallbackCheckWhenReady(kind: CheckKind) {
        fallbackRetryTimer?.invalidate()
        fallbackRetryTimer = nil
        fallbackRetryAttempts = 0
        let generation = checkGeneration
        scheduleFallbackRetry(kind: kind, generation: generation)
    }

    private func scheduleFallbackRetry(kind: CheckKind, generation: Int) {
        guard shouldRetryUsingFallback, generation == checkGeneration else { return }

        fallbackRetryTimer = Timer.scheduledTimer(
            withTimeInterval: UpdateCheckRecoveryPolicy.fallbackRetryInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.checkGeneration == generation else { return }
                self.fallbackRetryTimer = nil
                self.tryFallbackCheck(kind: kind, generation: generation)
            }
        }
    }

    private func tryFallbackCheck(kind: CheckKind, generation: Int) {
        guard shouldRetryUsingFallback, generation == checkGeneration else { return }

        guard updater.canCheckForUpdates else {
            fallbackRetryAttempts += 1
            if UpdateCheckRecoveryPolicy.hasExhaustedFallbackRetries(fallbackRetryAttempts) {
                shouldRetryUsingFallback = false
                finishUpdateCheckWithFailure(
                    pendingPrimaryError
                        ?? NSError(
                            domain: "KMGUpdateCoordinator",
                            code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey: "备用更新源暂时不可用，请稍后重试。"
                            ]
                        )
                )
            } else {
                scheduleFallbackRetry(kind: kind, generation: generation)
            }
            return
        }

        shouldRetryUsingFallback = false
        attemptedFallback = true
        beginCheck(kind, useFallback: true)
    }

    private func finishUpdateCheckWithFailure(_ error: Error) {
        let failure = UpdateFailure(
            stage: .download,
            title: "检查更新失败",
            message: error.localizedDescription,
            metadata: nil
        )
        resetAfterAbortedInstallation(finalState: .failed(failure))
    }

    private func invalidateCheckRecoveryTimers() {
        checkTimeoutTimer?.invalidate()
        checkTimeoutTimer = nil
        fallbackRetryTimer?.invalidate()
        fallbackRetryTimer = nil
        fallbackRetryAttempts = 0
    }

    private func resetAfterAbortedInstallation(finalState: UpdateCoordinatorState = .idle) {
        let wasPreparingInstallation: Bool
        switch state {
        case .ready, .installReplyPending, .waitingForTermination, .installing:
            wasPreparingInstallation = true
        default:
            wasPreparingInstallation = readyMetadata != nil
        }

        checkGeneration += 1
        invalidateCheckRecoveryTimers()
        shouldRetryUsingFallback = false
        pendingPrimaryError = nil
        attemptedFallback = false
        activeFeedURL = environment?.primaryFeedURL
        checkCancellation = nil
        downloadCancellation = nil
        readyChoiceReply = nil
        currentItem = nil
        readyMetadata = nil
        UpdatePreferences.setReadyMetadata(nil)
        expiryTimer?.invalidate()
        expiryTimer = nil
        clearTerminationRetry()
        state = finalState

        if wasPreparingInstallation {
            installationDidAbortHandler?()
        }
    }

    private func clearTerminationRetry() {
        retryTerminationGeneration += 1
        retryTerminationHandler = nil
        retryTerminationInFlight = false
        retryTerminationTimer?.invalidate()
        retryTerminationTimer = nil
    }
}

// MARK: - Sparkle user driver

extension UpdateCoordinator: SPUUserDriver {
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(
            SUUpdatePermissionResponse(
                automaticUpdateChecks: automaticUpdatesEnabled,
                automaticUpdateDownloading: false,
                sendSystemProfile: false
            )
        )
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        checkCancellation = cancellation
        state = .checking(manual: true)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state updateState: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        currentItem = appcastItem
        checkCancellation = nil
        checkTimeoutTimer?.invalidate()
        checkTimeoutTimer = nil
        shouldRetryUsingFallback = false
        pendingPrimaryError = nil

        if appcastItem.isInformationOnlyUpdate {
            if updateState.userInitiated, let infoURL = appcastItem.infoURL {
                NSWorkspace.shared.open(infoURL)
            }
            state = .idle
            reply(.dismiss)
            return
        }

        if shouldSuppress(appcastItem, userInitiated: updateState.userInitiated) {
            state = .suppressed(build: appcastItem.versionString)
            reply(.skip)
            return
        }

        if updateState.userInitiated && updateState.stage == .notDownloaded {
            showManualUpdatePrompt(item: appcastItem, reply: reply)
        } else {
            state = .downloading(progress: nil)
            reply(.install)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        Log.warning("[UpdateCoordinator] Release notes download failed: \(error)", category: .ui)
    }

    func showUpdateNotFoundWithError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        checkCancellation = nil
        checkGeneration += 1
        invalidateCheckRecoveryTimers()
        shouldRetryUsingFallback = false
        pendingPrimaryError = nil
        attemptedFallback = false
        activeFeedURL = environment?.primaryFeedURL
        if checkKind == .manual {
            showAlert(title: "已是最新版本", message: "当前没有可用的新版本。")
        }
        state = .idle
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if isCancellation(error) {
            resetAfterAbortedInstallation()
            acknowledgement()
            return
        }
        // Sparkle reports SUNoUpdateError through didAbortWithError after the
        // user driver has already presented the normal "up to date" result.
        // It is a successful terminal outcome, not a failed update check.
        if UpdateFallbackPolicy.isNoUpdateFound(error) {
            acknowledgement()
            return
        }
        let previousState = state
        scheduleFallbackIfNeeded(error: error)
        guard !shouldRetryUsingFallback else {
            acknowledgement()
            return
        }
        let failure: UpdateFailure?
        switch previousState {
        case .downloading:
            failure = UpdateFailure(stage: .download, title: "更新下载失败", message: error.localizedDescription, metadata: readyMetadata)
        case .preparing:
            failure = UpdateFailure(stage: .preparation, title: "更新准备失败", message: error.localizedDescription, metadata: readyMetadata)
        case .ready, .installReplyPending, .waitingForTermination, .installing:
            failure = UpdateFailure(stage: .installation, title: "更新安装失败", message: error.localizedDescription, metadata: readyMetadata)
        default:
            failure = UpdateFailure(stage: .download, title: "检查更新失败", message: error.localizedDescription, metadata: nil)
        }
        if let failure {
            resetAfterAbortedInstallation(finalState: .failed(failure))
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadCancellation = cancellation
        expectedDownloadLength = 0
        receivedDownloadLength = 0
        state = .downloading(progress: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedDownloadLength += length
        guard expectedDownloadLength > 0 else {
            state = .downloading(progress: nil)
            return
        }
        state = .downloading(
            progress: min(1, Double(receivedDownloadLength) / Double(expectedDownloadLength))
        )
    }

    func showDownloadDidStartExtractingUpdate() {
        downloadCancellation = nil
        state = .preparing(progress: nil)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        state = .preparing(progress: min(1, max(0, progress)))
    }

    func showReady(
        toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard let currentItem else {
            resetAfterAbortedInstallation()
            reply(.dismiss)
            return
        }

        if shouldSuppress(currentItem, userInitiated: checkKind == .manual) {
            reply(.skip)
            return
        }

        readyChoiceReply = reply
        markReady(item: currentItem)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        retryTerminationGeneration += 1
        retryTerminationTimer?.invalidate()
        retryTerminationTimer = nil
        retryTerminationInFlight = false
        if applicationTerminated {
            retryTerminationHandler = nil
            state = .installing
        } else {
            retryTerminationHandler = retryTerminatingApplication
            state = .waitingForTermination(readyMetadata, retryInFlight: false)
        }
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        clearTerminationRetry()
        if relaunched {
            UpdatePreferences.setReadyMetadata(nil)
            UpdatePreferences.setSuppressedBuild(nil)
            readyMetadata = nil
            state = .idle
        } else {
            state = .failed(
                UpdateFailure(
                    stage: .relaunch,
                    title: "更新已安装，但应用未能自动打开",
                    message: "请从应用程序文件夹手动打开新版本，然后重新检查更新。",
                    metadata: readyMetadata
                )
            )
        }
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        resetAfterAbortedInstallation()
    }

    private func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && [NSURLErrorCancelled, NSURLErrorUserCancelledAuthentication].contains(nsError.code)
    }

    func showUpdateInFocus() {
        if let metadata = readyMetadata {
            state = .ready(metadata)
        }
    }
}

// MARK: - Sparkle updater delegate

extension UpdateCoordinator: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        environment?.allowedSparkleChannels ?? []
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        activeFeedURL?.absoluteString ?? environment?.primaryFeedURL.absoluteString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        currentItem = item
        if UpdateBuildPolicy.shouldClearSuppression(
            candidateBuild: item.versionString,
            suppressedBuild: UpdatePreferences.suppressedBuild()
        ) {
            UpdatePreferences.setSuppressedBuild(nil)
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if case .failed = state { return }
        showUpdaterError(error, acknowledgement: {})
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        checkCancellation = nil

        if let error {
            scheduleFallbackIfNeeded(error: error)
        }

        if shouldRetryUsingFallback {
            let kind = checkKind
            scheduleFallbackCheckWhenReady(kind: kind)
            return
        }

        checkTimeoutTimer?.invalidate()
        checkTimeoutTimer = nil

        if let error, !isCancellation(error) {
            if UpdateFallbackPolicy.isNoUpdateFound(error) {
                // The user driver normally moves the state to idle first. Keep
                // this defensive branch so callback ordering cannot leave the
                // coordinator stuck in checking or mark a normal result failed.
                if case .checking = state {
                    state = .idle
                }
            } else {
                switch state {
                case .failed:
                    break
                case .checking:
                    finishUpdateCheckWithFailure(error)
                case .downloading, .preparing, .ready, .installReplyPending, .waitingForTermination, .installing:
                    showUpdaterError(error, acknowledgement: {})
                default:
                    break
                }
            }
        } else if error != nil {
            resetAfterAbortedInstallation()
        }

        activeFeedURL = environment?.primaryFeedURL
        attemptedFallback = false
        pendingPrimaryError = nil

        switch state {
        case .checking:
            state = .idle
        default:
            break
        }
    }

    func updater(
        _ updater: SPUUpdater,
        shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem
    ) -> Bool {
        false
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let terminationPreparationHandler else { return false }
        let handlerBox = UpdateCallbackBox(installHandler)
        terminationPreparationHandler {
            handlerBox.call()
        }
        return true
    }
}
