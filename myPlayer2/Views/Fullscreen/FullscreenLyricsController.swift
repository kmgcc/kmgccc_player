//
//  FullscreenLyricsController.swift
//  myPlayer2
//

import AppKit
import Foundation

@MainActor
@Observable
final class FullscreenLyricsController {
    var lockedBackgroundColor: NSColor?
    var lockedUltraDark = false
    var pendingBackgroundCapture = false
    var suppressViewport = false
    var hostMounted = false
    var coverBlurTheme: FullscreenCoverBlurLyricsTheme?

    private var pendingRefresh: DispatchWorkItem?
    private var pendingHostDetach: DispatchWorkItem?

    func handleAppear(
        isShowingLyricsPanel: Bool,
        currentTrackID: UUID?
    ) {
        hostMounted = isShowingLyricsPanel && currentTrackID != nil
    }

    func handleDisappear() {
        cancelPendingRefresh()
        cancelHostDetach()
        suppressViewport = false
        hostMounted = false
        coverBlurTheme = nil
        resetBackgroundSnapshot()
    }

    func prepareForShowingLyrics(hasTrack: Bool) {
        guard hasTrack else { return }
        cancelHostDetach()
        hostMounted = true
    }

    func syncHostMount(
        isShowingLyricsPanel: Bool,
        currentTrackID: UUID?,
        reduceMotion: Bool
    ) {
        let shouldShowLyricsHost = isShowingLyricsPanel && currentTrackID != nil

        cancelHostDetach()

        if shouldShowLyricsHost {
            hostMounted = true
            return
        }

        guard hostMounted else { return }
        scheduleHostDetach(
            after: reduceMotion ? 0.22 : 0.72,
            isShowingLyricsPanel: { isShowingLyricsPanel },
            currentTrackID: { currentTrackID }
        )
    }

    func shouldKeepHostMounted(currentTrackID: UUID?) -> Bool {
        hostMounted && currentTrackID != nil
    }

    func hostOpacity(
        isShowingLyricsPanel: Bool,
        currentTrackID: UUID?,
        coverBlurThemeReady: Bool
    ) -> Double {
        guard isShowingLyricsPanel, currentTrackID != nil else { return 0 }
        return coverBlurThemeReady ? 1 : 0
    }

    func viewportOpacity(
        currentTrackID: UUID?,
        coverBlurThemeReady: Bool
    ) -> Double {
        guard currentTrackID != nil else { return 0 }
        guard coverBlurThemeReady else { return 0 }
        return suppressViewport ? 0 : 1
    }

    func resetBackgroundSnapshot() {
        lockedBackgroundColor = nil
        lockedUltraDark = false
        pendingBackgroundCapture = false
    }

    func scheduleBackgroundCapture(
        isArtBackgroundActive: Bool,
        currentTrackID: UUID?
    ) {
        pendingBackgroundCapture = isArtBackgroundActive && currentTrackID != nil
    }

    func captureBackgroundSnapshot(
        isArtBackgroundActive: Bool,
        currentTrackID: UUID?,
        bkLyricsColorTrackID: UUID?,
        primaryBackgroundColor: NSColor?,
        surfaceBackgroundColor: NSColor?,
        isUltraDarkActive: Bool,
        preferLiveSurface: Bool = false
    ) {
        guard isArtBackgroundActive else {
            resetBackgroundSnapshot()
            return
        }

        guard bkLyricsColorTrackID == currentTrackID else {
            pendingBackgroundCapture = isArtBackgroundActive && currentTrackID != nil
            return
        }

        if preferLiveSurface {
            lockedBackgroundColor = surfaceBackgroundColor ?? primaryBackgroundColor
        } else {
            lockedBackgroundColor = primaryBackgroundColor ?? surfaceBackgroundColor
        }
        lockedUltraDark = isUltraDarkActive
        pendingBackgroundCapture = false
    }

    func refreshColors(
        captureSnapshot: (_ preferLiveSurface: Bool) -> Void,
        applyTheme: () -> Void
    ) {
        cancelPendingRefresh()
        resetBackgroundSnapshot()
        captureSnapshot(true)
        applyTheme()
    }

    func forceRefreshColors(
        reason: String,
        captureSnapshot: @escaping (_ preferLiveSurface: Bool) -> Void,
        applyTheme: @escaping (_ force: Bool, _ reason: String) -> Void
    ) {
        cancelPendingRefresh()

        resetBackgroundSnapshot()
        captureSnapshot(true)
        applyTheme(true, reason)

        let delayedReason = reason
        let delayedWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resetBackgroundSnapshot()
            captureSnapshot(true)
            applyTheme(true, "\(delayedReason)-delayed")
            self.pendingRefresh = nil
        }

        pendingRefresh = delayedWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: delayedWorkItem)
    }

    func scheduleLyricsRefresh(
        preferLiveSurface: Bool,
        captureSnapshot: @escaping (_ preferLiveSurface: Bool) -> Void,
        applyTheme: @escaping () -> Void
    ) {
        cancelPendingRefresh()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            captureSnapshot(preferLiveSurface)
            applyTheme()
            self.pendingRefresh = nil
        }

        pendingRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    func cancelPendingRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    private func cancelHostDetach() {
        pendingHostDetach?.cancel()
        pendingHostDetach = nil
    }

    private func scheduleHostDetach(
        after delay: TimeInterval,
        isShowingLyricsPanel: @escaping () -> Bool,
        currentTrackID: @escaping () -> UUID?
    ) {
        cancelHostDetach()

        let detachTrackID = currentTrackID()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if isShowingLyricsPanel() || currentTrackID() != detachTrackID {
                self.pendingHostDetach = nil
                return
            }
            self.hostMounted = false
            self.pendingHostDetach = nil
        }
        pendingHostDetach = workItem

        if delay <= 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
}
