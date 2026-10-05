import Observation
import SwiftUI

@Observable
@MainActor
final class FullscreenBottomControlsCoordinator {
    var isVisible = true
    var isHovered = false
    var isHotZoneHovered = false
    var isAppearancePanelHovered = false
    var isLeadingHovered = false
    var isCenterHovered = false
    var isTrailingHovered = false
    var isProgressDragging = false
    var isVolumeAdjusting = false
    var isLeftActionsExpanded = false
    var isVolumeExpanded = false
    var isQuickAppearancePanelPresented = false

    @ObservationIgnored private var pendingHideTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLeftCollapseTask: Task<Void, Never>?
    @ObservationIgnored private var pendingVolumeCollapseTask: Task<Void, Never>?
    @ObservationIgnored private var pendingHideTaskID: UUID?
    @ObservationIgnored private var pendingLeftCollapseTaskID: UUID?
    @ObservationIgnored private var pendingVolumeCollapseTaskID: UUID?

    func setVisible(
        _ visible: Bool,
        animate: (_ updates: () -> Void) -> Void
    ) {
        guard isVisible != visible else { return }
        animate {
            isVisible = visible
        }
    }

    /// Returns the hover value that should be applied to scene behavior. An
    /// unchanged inside state is returned again because the native lyric surface
    /// may have been created after the previous pointer event.
    func updateHoverGate(
        hotZone: Bool?,
        appearancePanel: Bool?,
        leading: Bool?,
        center: Bool?,
        trailing: Bool?
    ) -> Bool? {
        if let hotZone { isHotZoneHovered = hotZone }
        if let appearancePanel { isAppearancePanelHovered = appearancePanel }
        if let leading { isLeadingHovered = leading }
        if let center { isCenterHovered = center }
        if let trailing { isTrailingHovered = trailing }

        let isPointerInside =
            isHotZoneHovered
            || isAppearancePanelHovered
            || isLeadingHovered
            || isCenterHovered
            || isTrailingHovered

        guard isPointerInside != isHovered else {
            return isPointerInside ? true : nil
        }
        isHovered = isPointerInside
        return isPointerInside
    }

    func scheduleAutoHide(
        after delay: TimeInterval,
        shouldBlock: @escaping () -> Bool,
        setVisible: @escaping (Bool) -> Void,
        setLeftActionsExpanded: @escaping (Bool, String) -> Void,
        setVolumeExpanded: @escaping (Bool, String) -> Void,
        scheduleAgain: @escaping () -> Void
    ) {
        cancelAutoHide()
        guard delay > 0 else {
            setVisible(true)
            return
        }
        guard !shouldBlock() else { return }

        let taskID = UUID()
        pendingHideTaskID = taskID
        pendingHideTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.pendingHideTaskID == taskID {
                    self.pendingHideTask = nil
                    self.pendingHideTaskID = nil
                }
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            guard !shouldBlock() else {
                scheduleAgain()
                return
            }

            setVisible(false)
            setLeftActionsExpanded(false, "auto-hide")
            setVolumeExpanded(false, "auto-hide")
        }
    }

    func cancelAutoHide() {
        pendingHideTask?.cancel()
        pendingHideTask = nil
        pendingHideTaskID = nil
    }

    func scheduleLeftCollapse(
        reason: String,
        after nanoseconds: UInt64 = 180_000_000,
        setLeftActionsExpanded: @escaping (Bool, String) -> Void,
        scheduleAutoHide: @escaping () -> Void
    ) {
        cancelLeftCollapse()
        guard !isLeadingHovered else {
            logHover("left collapse skipped reason=\(reason) still-hovered")
            return
        }

        let taskID = UUID()
        pendingLeftCollapseTaskID = taskID
        pendingLeftCollapseTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.pendingLeftCollapseTaskID == taskID {
                    self.pendingLeftCollapseTask = nil
                    self.pendingLeftCollapseTaskID = nil
                }
            }
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard !self.isLeadingHovered else {
                self.logHover("left collapse cancelled reason=\(reason) hovered-after-delay")
                return
            }

            setLeftActionsExpanded(false, reason)
            scheduleAutoHide()
        }
    }

    func cancelLeftCollapse() {
        pendingLeftCollapseTask?.cancel()
        pendingLeftCollapseTask = nil
        pendingLeftCollapseTaskID = nil
    }

    func scheduleVolumeCollapse(
        reason: String,
        after nanoseconds: UInt64 = 180_000_000,
        setVolumeExpanded: @escaping (Bool, String) -> Void,
        scheduleAutoHide: @escaping () -> Void
    ) {
        cancelVolumeCollapse()
        guard !isTrailingHovered, !isVolumeAdjusting else {
            logHover("volume collapse skipped reason=\(reason) still-active")
            return
        }

        let taskID = UUID()
        pendingVolumeCollapseTaskID = taskID
        pendingVolumeCollapseTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.pendingVolumeCollapseTaskID == taskID {
                    self.pendingVolumeCollapseTask = nil
                    self.pendingVolumeCollapseTaskID = nil
                }
            }
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard !self.isTrailingHovered, !self.isVolumeAdjusting else {
                self.logHover("volume collapse cancelled reason=\(reason) active-after-delay")
                return
            }

            setVolumeExpanded(false, reason)
            scheduleAutoHide()
        }
    }

    func cancelVolumeCollapse() {
        pendingVolumeCollapseTask?.cancel()
        pendingVolumeCollapseTask = nil
        pendingVolumeCollapseTaskID = nil
    }

    func cancelSideControlCollapses() {
        cancelLeftCollapse()
        cancelVolumeCollapse()
    }

    func cancelAllScheduledWork() {
        cancelAutoHide()
        cancelSideControlCollapses()
    }

    func setLeftActionsExpanded(
        _ expanded: Bool,
        reason: String,
        animate: (_ updates: () -> Void) -> Void
    ) {
        guard isLeftActionsExpanded != expanded else {
            logHover("left unchanged reason=\(reason) expanded=\(expanded)")
            return
        }

        logHover(
            "left reason=\(reason) \(isLeftActionsExpanded)->\(expanded) hot=\(isHotZoneHovered) center=\(isCenterHovered) leadingHover=\(isLeadingHovered) trailing=\(isTrailingHovered)"
        )
        animate {
            isLeftActionsExpanded = expanded
        }
    }

    func setVolumeExpanded(
        _ expanded: Bool,
        reason: String,
        volumeControlEnabled: Bool,
        animate: (_ updates: () -> Void) -> Void
    ) {
        let nextValue = expanded && volumeControlEnabled
        guard isVolumeExpanded != nextValue else {
            logHover("volume unchanged reason=\(reason) expanded=\(nextValue)")
            return
        }

        logHover(
            "volume reason=\(reason) \(isVolumeExpanded)->\(nextValue) hot=\(isHotZoneHovered) center=\(isCenterHovered) leadingHover=\(isLeadingHovered) trailing=\(isTrailingHovered) adjusting=\(isVolumeAdjusting)"
        )
        animate {
            isVolumeExpanded = nextValue
        }
    }

    private func logHover(_ message: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: "Debug.fullscreenMiniPlayerHover") else { return }
        Log.info("FullscreenMiniPlayerHover: \(message())", category: .fullscreen)
    }
}
