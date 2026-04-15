//
//  FullscreenBottomControls.swift
//  myPlayer2
//

import SwiftUI

enum FullscreenBottomControlsMetrics {
    static let buttonSize: CGFloat = 60
    static let controlSpacing: CGFloat = 20
    static let horizontalPadding: CGFloat = 80
    static let bottomPadding: CGFloat = 72
    static let miniPlayerMaxWidth: CGFloat = 1200
    static let miniPlayerPillWidthReduction: CGFloat = 160
    static let leadingControlsExpandedWidth: CGFloat = 180
    static let leadingControlsCollapsedWidth: CGFloat = 120
    static let volumeExpandedWidth: CGFloat = 180
    static let volumeCollapsedWidth: CGFloat = 60
}

@MainActor
@Observable
final class FullscreenBottomControlsController {
    var isVolumeExpanded = false
    var isLeadingControlsExpanded = false
    var isVisible = true
    var isHovered = false
    var isHotZoneHovered = false
    var isLeadingHovered = false
    var isCenterHovered = false
    var isTrailingHovered = false
    var isProgressDragging = false
    var isVolumeAdjusting = false
    var appearanceRotateTrigger = 0

    private var pendingHide: DispatchWorkItem?

    func registerAppearanceRotationIfNeeded(currentAppearance: AppSettings.ManualAppearance) {
        if currentAppearance == .dark {
            appearanceRotateTrigger += 1
        }
    }

    func handleRightPanelStateChange(
        isQueueVisible: Bool,
        autoHideSeconds: Double,
        animation: Animation
    ) {
        if isQueueVisible {
            cancelAutoHide()
            if isVisible == false {
                withAnimation(animation) {
                    isVisible = true
                }
            }
            return
        }

        scheduleAutoHideIfNeeded(
            autoHideSeconds: autoHideSeconds,
            shouldKeepVisible: isQueueVisible,
            animation: animation
        )
    }

    func resetAutoHideState(
        autoHideSeconds: Double,
        shouldKeepVisible: Bool,
        animation: Animation
    ) {
        cancelAutoHide()
        isVisible = true
        isProgressDragging = false
        isVolumeAdjusting = false
        isHovered = false
        isHotZoneHovered = false
        isLeadingHovered = false
        isCenterHovered = false
        isTrailingHovered = false
        scheduleAutoHideIfNeeded(
            autoHideSeconds: autoHideSeconds,
            shouldKeepVisible: shouldKeepVisible,
            animation: animation
        )
    }

    func updateHoverGate(
        hotZone: Bool? = nil,
        leading: Bool? = nil,
        center: Bool? = nil,
        trailing: Bool? = nil,
        autoHideSeconds: Double,
        shouldKeepVisible: Bool,
        animation: Animation
    ) {
        if let hotZone {
            isHotZoneHovered = hotZone
        }
        if let leading {
            isLeadingHovered = leading
        }
        if let center {
            isCenterHovered = center
        }
        if let trailing {
            isTrailingHovered = trailing
        }

        let isPointerInsideControls =
            isHotZoneHovered
            || isLeadingHovered
            || isCenterHovered
            || isTrailingHovered

        guard isPointerInsideControls != isHovered else {
            if isPointerInsideControls {
                cancelAutoHide()
                if isVisible == false {
                    withAnimation(animation) {
                        isVisible = true
                    }
                }
            }
            return
        }

        handleHover(
            isPointerInsideControls,
            autoHideSeconds: autoHideSeconds,
            shouldKeepVisible: shouldKeepVisible,
            animation: animation
        )
    }

    func registerInteraction(
        autoHideSeconds: Double,
        shouldKeepVisible: Bool,
        animation: Animation
    ) {
        if isVisible == false {
            withAnimation(animation) {
                isVisible = true
            }
        }
        guard isHovered == false else {
            cancelAutoHide()
            return
        }
        scheduleAutoHideIfNeeded(
            autoHideSeconds: autoHideSeconds,
            shouldKeepVisible: shouldKeepVisible,
            animation: animation
        )
    }

    func setProgressDragging(
        _ dragging: Bool,
        autoHideSeconds: Double,
        shouldKeepVisible: Bool,
        animation: Animation
    ) {
        isProgressDragging = dragging
        if dragging {
            registerInteraction(
                autoHideSeconds: autoHideSeconds,
                shouldKeepVisible: shouldKeepVisible,
                animation: animation
            )
        } else {
            scheduleAutoHideIfNeeded(
                autoHideSeconds: autoHideSeconds,
                shouldKeepVisible: shouldKeepVisible,
                animation: animation
            )
        }
    }

    func setVolumeAdjusting(
        _ adjusting: Bool,
        autoHideSeconds: Double,
        shouldKeepVisible: Bool,
        animation: Animation
    ) {
        isVolumeAdjusting = adjusting
        if adjusting {
            registerInteraction(
                autoHideSeconds: autoHideSeconds,
                shouldKeepVisible: shouldKeepVisible,
                animation: animation
            )
        } else {
            scheduleAutoHideIfNeeded(
                autoHideSeconds: autoHideSeconds,
                shouldKeepVisible: shouldKeepVisible,
                animation: animation
            )
        }
    }

    func scheduleAutoHideIfNeeded(
        autoHideSeconds: Double,
        shouldKeepVisible: Bool,
        animation: Animation
    ) {
        cancelAutoHide()
        guard autoHideSeconds > 0 else {
            if isVisible == false {
                withAnimation(animation) {
                    isVisible = true
                }
            }
            return
        }
        guard shouldBlockAutoHide(shouldKeepVisible: shouldKeepVisible) == false else {
            return
        }

        let hideWorkItem = DispatchWorkItem { @MainActor in
            guard self.shouldBlockAutoHide(shouldKeepVisible: shouldKeepVisible) == false else {
                self.scheduleAutoHideIfNeeded(
                    autoHideSeconds: autoHideSeconds,
                    shouldKeepVisible: shouldKeepVisible,
                    animation: animation
                )
                return
            }
            withAnimation(animation) {
                self.isVisible = false
            }
        }
        pendingHide = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideSeconds, execute: hideWorkItem)
    }

    func cancelAutoHide() {
        pendingHide?.cancel()
        pendingHide = nil
    }

    private func handleHover(
        _ hovering: Bool,
        autoHideSeconds: Double,
        shouldKeepVisible: Bool,
        animation: Animation
    ) {
        isHovered = hovering
        if hovering {
            cancelAutoHide()
            if isVisible == false {
                withAnimation(animation) {
                    isVisible = true
                }
            }
        } else {
            scheduleAutoHideIfNeeded(
                autoHideSeconds: autoHideSeconds,
                shouldKeepVisible: shouldKeepVisible,
                animation: animation
            )
        }
    }

    private func shouldBlockAutoHide(shouldKeepVisible: Bool) -> Bool {
        shouldKeepVisible
            || isHovered
            || isLeadingControlsExpanded
            || isVolumeExpanded
            || isProgressDragging
            || isVolumeAdjusting
    }
}

struct FullscreenBottomControlsView: View {
    @Bindable var controller: FullscreenBottomControlsController

    let scale: CGFloat
    let screenHeight: CGFloat
    let glassStyle: FullscreenControlsGlassStyle
    let playbackMode: PlaybackOrderMode
    let volume: Binding<Double>
    let primaryColor: Color
    let controlsColorScheme: ColorScheme
    let effectiveAppearance: AppSettings.ManualAppearance
    let isLyricsVisible: Bool
    let canToggleLyrics: Bool
    let autoHideSeconds: Double
    let shouldKeepVisible: Bool
    let animation: Animation
    let onExitFullscreen: () -> Void
    let onToggleLyrics: () -> Void
    let onCycleAppearance: () -> Void
    let onPlaybackModeChange: (PlaybackOrderMode) -> Void
    let onCurrentPlaybackModeRetap: (PlaybackOrderMode) -> Void

    var body: some View {
        let buttonSize = FullscreenBottomControlsMetrics.buttonSize
        let spacing = FullscreenBottomControlsMetrics.controlSpacing
        let windowWidth: CGFloat = FullscreenPlayerView.baseCanvasWidth

        let leadingControlsWidth = controller.isLeadingControlsExpanded
            ? FullscreenBottomControlsMetrics.leadingControlsExpandedWidth
            : FullscreenBottomControlsMetrics.leadingControlsCollapsedWidth
        let leadingControlsExtraWidth =
            leadingControlsWidth - FullscreenBottomControlsMetrics.leadingControlsCollapsedWidth
        let volumeWidth = controller.isVolumeExpanded
            ? FullscreenBottomControlsMetrics.volumeExpandedWidth
            : FullscreenBottomControlsMetrics.volumeCollapsedWidth
        let volumeExtraWidth = volumeWidth - FullscreenBottomControlsMetrics.volumeCollapsedWidth
        let leadingMiniPlayerOriginX = FullscreenBottomControlsMetrics.leadingControlsCollapsedWidth + spacing
        let fixedControlWidth =
            FullscreenBottomControlsMetrics.leadingControlsCollapsedWidth
            + spacing
            + spacing
            + FullscreenBottomControlsMetrics.volumeCollapsedWidth
        let availableGroupWidth = max(
            0,
            windowWidth - FullscreenBottomControlsMetrics.horizontalPadding * 2
        )
        let collapsedMiniPlayerWidth = max(
            0,
            min(availableGroupWidth - fixedControlWidth, FullscreenBottomControlsMetrics.miniPlayerMaxWidth)
                - FullscreenBottomControlsMetrics.miniPlayerPillWidthReduction
        )
        let groupWidth = fixedControlWidth + collapsedMiniPlayerWidth
        let currentMiniPlayerWidth = max(
            0,
            collapsedMiniPlayerWidth - leadingControlsExtraWidth - volumeExtraWidth
        )
        let groupOriginX = max(0, (windowWidth - groupWidth) * 0.5)
        let leadingControlsOriginX = groupOriginX
        let miniPlayerOriginX = groupOriginX + leadingMiniPlayerOriginX + leadingControlsExtraWidth
        let volumeOriginX = max(0, groupOriginX + groupWidth - volumeWidth)

        let scaledButtonSize = buttonSize * scale
        let scaledLeadingControlsOriginX = leadingControlsOriginX * scale
        let scaledLeadingControlsWidth = leadingControlsWidth * scale
        let scaledMiniPlayerOriginX = miniPlayerOriginX * scale
        let scaledMiniPlayerWidth = currentMiniPlayerWidth * scale
        let scaledVolumeOriginX = volumeOriginX * scale
        let scaledVolumeWidth = volumeWidth * scale
        let scaledWindowWidth = windowWidth * scale
        let canvasBottomMargin = max(0, (screenHeight - FullscreenPlayerView.baseCanvasHeight * scale) / 2)
        let scaledBottomPadding = FullscreenBottomControlsMetrics.bottomPadding * scale + canvasBottomMargin
        let scaledGroupWidth = groupWidth * scale
        let hotZoneWidth = min(scaledWindowWidth, scaledGroupWidth + 120 * scale)
        let hotZoneHeight = scaledButtonSize + 34 * scale
        let controlsRowHeight = max(scaledButtonSize, hotZoneHeight)
        let controlsCenterY = controlsRowHeight * 0.5
        let adjustedBottomPadding = max(
            0,
            scaledBottomPadding - (controlsRowHeight - scaledButtonSize) * 0.5
        )

        VStack {
            Spacer()
            ZStack(alignment: .leading) {
                Color.white.opacity(0.001)
                    .frame(width: hotZoneWidth, height: hotZoneHeight)
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: hotZoneHeight * 0.5,
                            style: .continuous
                        )
                    )
                    .position(x: scaledWindowWidth * 0.5, y: controlsCenterY)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            controller.updateHoverGate(
                                hotZone: true,
                                autoHideSeconds: autoHideSeconds,
                                shouldKeepVisible: shouldKeepVisible,
                                animation: animation
                            )
                        case .ended:
                            controller.updateHoverGate(
                                hotZone: false,
                                autoHideSeconds: autoHideSeconds,
                                shouldKeepVisible: shouldKeepVisible,
                                animation: animation
                            )
                        }
                    }

                ZStack(alignment: .leading) {
                    leadingControlsPill(
                        size: scaledButtonSize,
                        materialStyle: glassStyle.materialStyle
                    )
                    .glassEffectTransition(.materialize)
                    .frame(width: scaledLeadingControlsWidth, height: scaledButtonSize)
                    .position(
                        x: scaledLeadingControlsOriginX + scaledLeadingControlsWidth / 2,
                        y: controlsCenterY
                    )

                    FullscreenMiniPlayerView(
                        scale: scale,
                        glassStyle: glassStyle,
                        playbackMode: playbackMode,
                        onPlaybackModeChange: onPlaybackModeChange,
                        onCurrentPlaybackModeRetap: onCurrentPlaybackModeRetap,
                        onInteraction: {
                            controller.registerInteraction(
                                autoHideSeconds: autoHideSeconds,
                                shouldKeepVisible: shouldKeepVisible,
                                animation: animation
                            )
                        },
                        onHoverStateChanged: { hovering in
                            controller.updateHoverGate(
                                center: hovering,
                                autoHideSeconds: autoHideSeconds,
                                shouldKeepVisible: shouldKeepVisible,
                                animation: animation
                            )
                            if hovering {
                                controller.registerInteraction(
                                    autoHideSeconds: autoHideSeconds,
                                    shouldKeepVisible: shouldKeepVisible,
                                    animation: animation
                                )
                            }
                        },
                        onProgressDraggingChanged: { dragging in
                            controller.setProgressDragging(
                                dragging,
                                autoHideSeconds: autoHideSeconds,
                                shouldKeepVisible: shouldKeepVisible,
                                animation: animation
                            )
                        }
                    )
                    .glassEffectTransition(.materialize)
                    .frame(width: scaledMiniPlayerWidth, height: scaledButtonSize)
                    .environment(\.colorScheme, glassStyle.colorScheme)
                    .position(
                        x: scaledMiniPlayerOriginX + scaledMiniPlayerWidth / 2,
                        y: controlsCenterY
                    )

                    ExpandableVolumeControl(
                        volume: volume,
                        isExpanded: $controller.isVolumeExpanded,
                        scale: scale,
                        onInteraction: {
                            controller.registerInteraction(
                                autoHideSeconds: autoHideSeconds,
                                shouldKeepVisible: shouldKeepVisible,
                                animation: animation
                            )
                        },
                        onHoverStateChanged: { hovering in
                            controller.updateHoverGate(
                                trailing: hovering,
                                autoHideSeconds: autoHideSeconds,
                                shouldKeepVisible: shouldKeepVisible,
                                animation: animation
                            )
                            if hovering {
                                controller.registerInteraction(
                                    autoHideSeconds: autoHideSeconds,
                                    shouldKeepVisible: shouldKeepVisible,
                                    animation: animation
                                )
                            } else {
                                controller.scheduleAutoHideIfNeeded(
                                    autoHideSeconds: autoHideSeconds,
                                    shouldKeepVisible: shouldKeepVisible,
                                    animation: animation
                                )
                            }
                        },
                        onAdjustingChanged: { adjusting in
                            controller.setVolumeAdjusting(
                                adjusting,
                                autoHideSeconds: autoHideSeconds,
                                shouldKeepVisible: shouldKeepVisible,
                                animation: animation
                            )
                        },
                        materialStyle: glassStyle.materialStyle
                    )
                    .glassEffectTransition(.materialize)
                    .frame(width: scaledVolumeWidth, height: scaledButtonSize)
                    .environment(\.colorScheme, glassStyle.colorScheme)
                    .position(
                        x: scaledVolumeOriginX + scaledVolumeWidth / 2,
                        y: controlsCenterY
                    )
                }
                .opacity(controller.isVisible ? 1 : 0)
                .allowsHitTesting(controller.isVisible)
                .accessibilityHidden(!controller.isVisible)
            }
            .frame(width: scaledWindowWidth, height: controlsRowHeight, alignment: .leading)
            .padding(.bottom, adjustedBottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(animation, value: controller.isLeadingControlsExpanded)
        .animation(animation, value: controller.isVolumeExpanded)
        .animation(animation, value: controller.isVisible)
    }

    private func leadingControlsPill(
        size: CGFloat,
        materialStyle: LiquidGlassPillMaterialStyle
    ) -> some View {
        let scaleFactor = size / FullscreenBottomControlsMetrics.buttonSize

        return HStack(spacing: 0) {
            leadingControlButton(size: size, help: "fullscreen.exit") {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(primaryColor)
                    .compositingGroup()
                    .blendMode(.screen)
            } action: {
                onExitFullscreen()
            }

            lyricsVisibilityButton(size: size)

            appearanceSwitchButton(size: size)
                .opacity(controller.isLeadingControlsExpanded ? 1 : 0)
                .allowsHitTesting(controller.isLeadingControlsExpanded)
                .accessibilityHidden(!controller.isLeadingControlsExpanded)
        }
        .frame(
            width: controller.isLeadingControlsExpanded
                ? FullscreenBottomControlsMetrics.leadingControlsExpandedWidth * scaleFactor
                : FullscreenBottomControlsMetrics.leadingControlsCollapsedWidth * scaleFactor,
            height: size,
            alignment: .leading
        )
        .contentShape(Capsule())
        .liquidGlassPill(
            colorScheme: controlsColorScheme,
            accentColor: nil as Color?,
            prominence: .standard,
            materialStyle: materialStyle,
            isFloating: true
        )
        .environment(\.colorScheme, controlsColorScheme)
        .onHover { hovering in
            controller.updateHoverGate(
                leading: hovering,
                autoHideSeconds: autoHideSeconds,
                shouldKeepVisible: shouldKeepVisible,
                animation: animation
            )
            controller.isLeadingControlsExpanded = hovering
            if hovering {
                controller.registerInteraction(
                    autoHideSeconds: autoHideSeconds,
                    shouldKeepVisible: shouldKeepVisible,
                    animation: animation
                )
            } else {
                controller.scheduleAutoHideIfNeeded(
                    autoHideSeconds: autoHideSeconds,
                    shouldKeepVisible: shouldKeepVisible,
                    animation: animation
                )
            }
        }
    }

    private func leadingControlButton<Label: View>(
        size: CGFloat,
        help: LocalizedStringKey,
        @ViewBuilder label: () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            controller.registerInteraction(
                autoHideSeconds: autoHideSeconds,
                shouldKeepVisible: shouldKeepVisible,
                animation: animation
            )
            action()
        } label: {
            label()
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func appearanceSwitchButton(size: CGFloat) -> some View {
        let icon = effectiveAppearance == .dark ? "moon" : "sun.max"
        let helpText: LocalizedStringKey =
            effectiveAppearance == .dark ? "sidebar.appearance_dark" : "sidebar.appearance_light"

        return leadingControlButton(size: size, help: helpText) {
            Image(systemName: icon)
                .id(icon)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(primaryColor)
                .compositingGroup()
                .blendMode(.screen)
                .symbolEffect(.rotate, value: controller.appearanceRotateTrigger)
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                )
                .animation(.snappy(duration: 0.24), value: icon)
        } action: {
            controller.registerAppearanceRotationIfNeeded(currentAppearance: effectiveAppearance)
            onCycleAppearance()
        }
    }

    private func lyricsVisibilityButton(size: CGFloat) -> some View {
        let icon = isLyricsVisible ? "quote.bubble.fill" : "quote.bubble"
        let helpText: LocalizedStringKey = isLyricsVisible ? "Hide Lyrics" : "Show Lyrics"

        return leadingControlButton(size: size, help: helpText) {
            Image(systemName: icon)
                .id(icon)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(primaryColor.opacity(canToggleLyrics ? 1 : 0.45))
                .compositingGroup()
                .blendMode(.screen)
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                )
                .animation(.snappy(duration: 0.22), value: icon)
        } action: {
            onToggleLyrics()
        }
        .disabled(!canToggleLyrics)
    }
}
