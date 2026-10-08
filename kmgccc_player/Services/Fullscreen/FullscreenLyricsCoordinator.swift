import AppKit
import Foundation
import Observation
import SwiftUI

struct FullscreenCoverBlurLyricsTheme {
    let trackID: UUID
    let themeColor: NSColor
    let themeLightness: CGFloat
    let profile: LyricsCoverBlurBlendProfile
    let palette: FullscreenLyricSemanticPalette

    var colors: LyricsSurfaceColorSet { palette.foregroundColorSet }
}

struct FullscreenLyricsAutoHideSnapshot {
    let trackID: UUID?
    let displayTrackID: UUID?
    let hasDisplayableLyrics: Bool
    let ttml: String?
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let isLyricsPanelVisible: Bool
    let isRightPanelHidden: Bool
    let displayHasTrack: Bool
    let visualOffsetSeconds: TimeInterval
}

struct FullscreenLyricsAutoHideEvent {
    let trailingGap: TimeInterval
    let visualLastEnd: TimeInterval
    let trackID: UUID?
}

struct FullscreenLyricsAutoHideEffects {
    var preloadTrackID: UUID?
    var autoHide: FullscreenLyricsAutoHideEvent?
}

@Observable
@MainActor
final class FullscreenLyricsCoordinator {
    var autoHiddenForEmptyContent = false
    var autoHiddenAfterEnding = false
    var autoHiddenAfterEndingCanRestore = false
    var autoHideTrackID: UUID?
    var lastEndTime: TimeInterval?
    var lastVisualEndTime: TimeInterval?
    var endingAutoHideSuppressedTrackID: UUID?
    var restoreInitialZeroTrackID: UUID?
    var pendingAutoRestoreTrackID: UUID?
    var suppressViewport = false

    var hostMounted = false
    var lockedBackgroundColor: NSColor?
    var lockedBackgroundIsUltraDark = false
    var pendingBackgroundCapture = false
    var deferredTrackUpdateDeadline: Date?
    var embeddedStartupRetryCount = 0
    var coverBlurTheme: FullscreenCoverBlurLyricsTheme?

    enum ScheduledWork: Hashable {
        case refresh, reveal, autoRestoreReload, autoRestoreReveal
        case hostDetach, trackRefresh, themeReapply, embeddedStartupRetry
    }

    @ObservationIgnored private var scheduledWork: [ScheduledWork: DispatchWorkItem] = [:]

    /// Replacing work for the same purpose cancels the previous callback.
    /// Zero-delay work remains queued unless the caller requires the existing
    /// synchronous track-refresh behavior.
    func schedule(
        _ kind: ScheduledWork,
        after delay: TimeInterval = 0,
        runImmediately: Bool = false,
        action: @escaping () -> Void
    ) {
        cancel(kind)
        let item = DispatchWorkItem { [weak self] in
            self?.scheduledWork.removeValue(forKey: kind)
            action()
        }
        scheduledWork[kind] = item
        if delay <= 0, runImmediately {
            item.perform()
        } else if delay <= 0 {
            DispatchQueue.main.async(execute: item)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func cancel(_ kind: ScheduledWork) {
        scheduledWork.removeValue(forKey: kind)?.cancel()
    }

    func shouldPreserveEndingAutoHideRestore(rightPanelIsHidden: Bool) -> Bool {
        autoHiddenAfterEnding
            && autoHiddenAfterEndingCanRestore
            && rightPanelIsHidden
    }

    func lyricsSurfaceTime(_ currentTime: TimeInterval, trackID: UUID?) -> TimeInterval {
        guard currentTime.isFinite else { return 0 }
        guard let trackID, restoreInitialZeroTrackID == trackID else { return currentTime }
        return 0
    }

    func shouldStartAtZero(trackID: UUID?, hasDisplayableLyrics: Bool) -> Bool {
        guard hasDisplayableLyrics,
              let trackID,
              restoreInitialZeroTrackID == trackID
        else { return false }
        return true
    }

    func shouldDeferAutoRestoreApply(
        trackID: UUID?,
        hasDisplayableLyrics: Bool,
        reason: String,
        autoRestoreReason: String
    ) -> Bool {
        guard hasDisplayableLyrics,
              let trackID,
              pendingAutoRestoreTrackID == trackID
        else { return false }
        return reason != autoRestoreReason
    }

    func prepareForLyricsButtonTap(isAutomatic: Bool, trackID: UUID?) {
        autoHiddenForEmptyContent = false
        guard !isAutomatic else { return }
        autoHiddenAfterEndingCanRestore = false
        endingAutoHideSuppressedTrackID = trackID
        restoreInitialZeroTrackID = nil
        pendingAutoRestoreTrackID = nil
        cancel(.autoRestoreReload)
        cancel(.autoRestoreReveal)
        suppressViewport = false
    }

    func resetForDisappear() {
        cancelAllScheduledWork()
        suppressViewport = false
        hostMounted = false
        autoHiddenAfterEnding = false
        autoHiddenAfterEndingCanRestore = false
        autoHideTrackID = nil
        lastEndTime = nil
        lastVisualEndTime = nil
        endingAutoHideSuppressedTrackID = nil
        restoreInitialZeroTrackID = nil
        pendingAutoRestoreTrackID = nil
        embeddedStartupRetryCount = 0
        deferredTrackUpdateDeadline = nil
    }

    func resetEndingAutoHide(
        restoreIfNeeded: Bool,
        nextTrackHasDisplayableLyrics: Bool = false,
        nextTrackID: UUID? = nil,
        preserveRestoreEligibility: Bool = false,
        rightPanelIsHidden: Bool,
        displayHasTrack: Bool
    ) -> UUID? {
        var scheduledAutoRestore = false
        var preloadTrackID: UUID?
        if restoreIfNeeded,
           autoHiddenAfterEnding,
           autoHiddenAfterEndingCanRestore,
           rightPanelIsHidden,
           displayHasTrack
        {
            if nextTrackHasDisplayableLyrics {
                restoreInitialZeroTrackID = nextTrackID
                pendingAutoRestoreTrackID = nextTrackID
                scheduledAutoRestore = true
                preloadTrackID = nextTrackID
            } else {
                autoHiddenForEmptyContent = true
                restoreInitialZeroTrackID = nil
                pendingAutoRestoreTrackID = nil
                suppressViewport = false
            }
        }
        if preserveRestoreEligibility {
            lastEndTime = nil
            lastVisualEndTime = nil
            return preloadTrackID
        }
        autoHiddenAfterEnding = false
        autoHiddenAfterEndingCanRestore = false
        lastEndTime = nil
        lastVisualEndTime = nil
        endingAutoHideSuppressedTrackID = nil
        if !scheduledAutoRestore {
            restoreInitialZeroTrackID = nil
            pendingAutoRestoreTrackID = nil
            suppressViewport = false
        }
        return preloadTrackID
    }

    func updateAutoHide(
        _ snapshot: FullscreenLyricsAutoHideSnapshot,
        trailingGapThreshold: TimeInterval,
        delayAfterFinalLine: TimeInterval
    ) -> FullscreenLyricsAutoHideEffects {
        var effects = FullscreenLyricsAutoHideEffects(preloadTrackID: nil, autoHide: nil)
        let trackChanged = autoHideTrackID != snapshot.trackID
        if trackChanged {
            if snapshot.trackID == nil,
               shouldPreserveEndingAutoHideRestore(rightPanelIsHidden: snapshot.isRightPanelHidden)
            {
                lastEndTime = nil
                lastVisualEndTime = nil
                return effects
            }
            effects.preloadTrackID = resetEndingAutoHide(
                restoreIfNeeded: true,
                nextTrackHasDisplayableLyrics: snapshot.hasDisplayableLyrics,
                nextTrackID: snapshot.trackID,
                rightPanelIsHidden: snapshot.isRightPanelHidden,
                displayHasTrack: snapshot.displayHasTrack
            )
            autoHideTrackID = snapshot.trackID
        }

        guard snapshot.hasDisplayableLyrics, let ttml = snapshot.ttml else {
            lastEndTime = nil
            lastVisualEndTime = nil
            return effects
        }

        let rawLastEndTime = FullscreenTTMLTimingExtractor.lastMainLineEndTime(in: ttml)
        lastEndTime = rawLastEndTime
        lastVisualEndTime = rawLastEndTime.map {
            max(0, $0 + snapshot.visualOffsetSeconds)
        }
        effects.autoHide = evaluateAutoHide(
            snapshot,
            trailingGapThreshold: trailingGapThreshold,
            delayAfterFinalLine: delayAfterFinalLine
        )
        return effects
    }

    func evaluateAutoHide(
        _ snapshot: FullscreenLyricsAutoHideSnapshot,
        trailingGapThreshold: TimeInterval,
        delayAfterFinalLine: TimeInterval
    ) -> FullscreenLyricsAutoHideEvent? {
        guard snapshot.isPlaying else { return nil }
        guard snapshot.isLyricsPanelVisible else { return nil }
        guard !autoHiddenAfterEnding else { return nil }
        guard endingAutoHideSuppressedTrackID != snapshot.displayTrackID else { return nil }
        guard let lastEnd = lastEndTime, lastEnd.isFinite else { return nil }
        guard snapshot.currentTime.isFinite, snapshot.duration.isFinite, snapshot.duration > 0 else { return nil }
        let trailingGap = snapshot.duration - lastEnd
        guard trailingGap >= trailingGapThreshold else { return nil }
        let visualLastEnd = lastVisualEndTime ?? lastEnd
        let hideTime = visualLastEnd + delayAfterFinalLine
        guard snapshot.currentTime >= hideTime else { return nil }

        autoHiddenAfterEnding = true
        autoHiddenAfterEndingCanRestore = true
        return FullscreenLyricsAutoHideEvent(
            trailingGap: trailingGap,
            visualLastEnd: visualLastEnd,
            trackID: autoHideTrackID
        )
    }

    func cancelThemeWork() {
        cancel(.refresh)
        cancel(.reveal)
        cancel(.themeReapply)
    }

    func cancelAllScheduledWork() {
        scheduledWork.values.forEach { $0.cancel() }
        scheduledWork.removeAll()
    }
}
