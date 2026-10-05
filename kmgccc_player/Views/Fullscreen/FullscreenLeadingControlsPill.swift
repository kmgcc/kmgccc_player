import MotionKit
import SwiftUI

/// Shared left capsule. The native player uses this exact view; authors may also place it alone.
struct FullscreenLeadingControlsPill: View {
    let size: CGFloat
    let presentation: FullscreenBottomBarPresentation
    let actions: FullscreenBottomBarActions
    @Bindable var controls: FullscreenBottomControlsCoordinator
    var isFullscreen = true
    var showsLyricsButton = true
    var alwaysShowsQuickPanel = false
    var onHoverStateChanged: ((Bool) -> Void)? = nil

    var body: some View {
        let controlColorScheme = presentation.glassStyle.colorScheme
        let foregroundProfile = presentation.miniPlayerForegroundProfile

        return HStack(spacing: 0) {
            leadingControlButton(size: size, help: isFullscreen ? "fullscreen.exit" : "全屏播放") {
                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(presentation.primaryColor)
                    .compositingGroup()
                    .blendMode(presentation.iconBlendMode)
                    .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
            } action: {
                actions.exitFullscreen()
            }

            if showsLyricsButton { lyricsVisibilityButton(size: size) }

            quickAppearanceButton(size: size)
                .opacity((alwaysShowsQuickPanel || controls.isLeftActionsExpanded) ? 1 : 0)
                .allowsHitTesting(alwaysShowsQuickPanel || controls.isLeftActionsExpanded)
                .accessibilityHidden(!alwaysShowsQuickPanel && !controls.isLeftActionsExpanded)
        }
        .frame(
            width: size * CGFloat(1 + (showsLyricsButton ? 1 : 0) + ((alwaysShowsQuickPanel || controls.isLeftActionsExpanded) ? 1 : 0)),
            height: size,
            alignment: .leading
        )
        .contentShape(Capsule())
        .skinControlRegion()
        .liquidGlassPill(
            colorScheme: controlColorScheme,
            accentColor: nil as Color?,
            prominence: .standard,
            materialStyle: presentation.glassStyle.materialStyle,
            isFloating: true
        )
        .animation(nil, value: foregroundProfile)
        .environment(\.colorScheme, controlColorScheme)
        .onHover { hovering in
            if let onHoverStateChanged { onHoverStateChanged(hovering) }
            else { actions.leadingHoverChanged(hovering) }
        }
    }

    private func leadingControlButton<Label: View>(
        size: CGFloat,
        help: LocalizedStringKey,
        @ViewBuilder label: () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            actions.interaction()
            action()
        } label: {
            label()
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func quickAppearanceButton(size: CGFloat) -> some View {
        let icon = controls.isQuickAppearancePanelPresented ? "paintpalette.fill" : "paintpalette"
        return leadingControlButton(size: size, help: "快速外观") {
            Image(systemName: icon)
                .id(icon)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(presentation.primaryColor)
                .compositingGroup()
                .blendMode(presentation.iconBlendMode)
                .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                )
                .motionAnimation(.microInteraction, value: icon)
        } action: {
            actions.setQuickAppearancePanelPresented(!controls.isQuickAppearancePanelPresented)
        }
    }

    private func lyricsVisibilityButton(size: CGFloat) -> some View {
        let icon = presentation.isShowingLyrics ? "quote.bubble.fill" : "quote.bubble"
        let helpText: LocalizedStringKey = presentation.isShowingLyrics ? "Hide Lyrics" : "Show Lyrics"
        return leadingControlButton(size: size, help: helpText) {
            Image(systemName: icon)
                .id(icon)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(presentation.primaryColor.opacity(presentation.hasTrack ? 1 : 0.45))
                .compositingGroup()
                .blendMode(presentation.iconBlendMode)
                .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                )
                .motionAnimation(.microInteraction, value: icon)
        } action: {
            actions.toggleLyrics()
        }
        .disabled(!presentation.hasTrack)
    }
}
