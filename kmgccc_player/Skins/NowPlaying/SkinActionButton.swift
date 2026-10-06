import SwiftUI

/// Single official controls for authors who compose their own transport layout.
struct SkinActionButton: View {
    enum Kind: String, CaseIterable {
        case playPause, previous, next, lyricsToggle, fullscreen, settings, quickPanel
        var symbol: String {
            switch self {
            case .playPause: "play.fill"
            case .previous: "backward.end.fill"
            case .next: "forward.end.fill"
            case .lyricsToggle: "quote.bubble"
            case .fullscreen: "arrow.up.left.and.arrow.down.right"
            case .settings: "gearshape"
            case .quickPanel: "paintpalette"
            }
        }
    }
    var reportsControls = true
    let kind: Kind
    let configuration: SkinComponentConfiguration
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinSceneSurface) private var surface
    @Environment(\.skinSceneActions) private var actions
    @Environment(\.skinNativeControls) private var native

    var body: some View {
        Button(action: invoke) {
            Image(systemName: symbol)
                .font(.system(size: configuration.number("fontSize", fallback: 20), weight: .semibold))
                .foregroundStyle(configuration.color(fallback: .primary))
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
        .skinControlRegion()
        .skinProvidesControls(reportsControls ? (SkinSceneControl(rawValue: kind.rawValue).map { [$0] } ?? []) : [])
    }

    private var symbol: String {
        if kind == .playPause { return playback.stablePresentation.isPlaying ? "pause.fill" : "play.fill" }
        if kind == .lyricsToggle, native?.presentation.isShowingLyrics == true { return "quote.bubble.fill" }
        if kind == .fullscreen && surface == .fullscreen { return "arrow.down.right.and.arrow.up.left" }
        return kind.symbol
    }
    private var disabled: Bool {
        switch kind {
        case .playPause: !playback.stablePresentation.isControlEnabled
        case .previous, .next: !playback.stablePresentation.isControlEnabled || !playback.stablePresentation.hasTrack
        default: false
        }
    }
    private var label: LocalizedStringKey {
        switch kind {
        case .playPause: playback.stablePresentation.isPlaying ? "Pause" : "Play"
        case .previous: "Previous Track"
        case .next: "Next Track"
        case .lyricsToggle: native?.presentation.isShowingLyrics == true ? "Hide Lyrics" : "Show Lyrics"
        case .fullscreen: surface == .fullscreen ? "fullscreen.exit" : "全屏播放"
        case .settings: "设置"
        case .quickPanel: "快速外观"
        }
    }
    private func invoke() {
        switch kind {
        case .playPause: actions.playPause()
        case .previous: actions.previous()
        case .next: actions.next()
        case .lyricsToggle: actions.toggleLyrics()
        case .fullscreen: surface == .fullscreen ? actions.exit() : actions.enterFullscreen()
        case .settings: actions.openSettings()
        case .quickPanel: actions.openQuickPanel()
        }
    }
}
