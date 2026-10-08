import SwiftUI

/// The scene owns activation and styling; the manager owns the renderer and the playback pipeline.
struct SkinSceneNativeLyricsLifecycle: View {
    let role: LyricsSurfaceRole
    let configuration: SkinComponentConfiguration?
    let isVisible: Bool
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LyricsViewModel.self) private var lyricsVM
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var theme: ThemeStore
    @State private var owner = UUID()
    @AppStorage("amllLyricsRenderQuality") private var renderQuality: String = "medium"

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { synchronize() }
            .onChange(of: isVisible) { _, _ in synchronize() }
            .onChange(of: configuration) { _, _ in applyAuthorConfiguration() }
            .onChange(of: reduceMotion) { _, _ in applyAuthorConfiguration() }
            .onChange(of: theme.colorScheme) { _, _ in
                if role == .main && isVisible { lyricsVM.refreshConfigFromSettings() }
            }
            .onChange(of: renderQuality) { _, value in
                if role == .main && isVisible {
                    let scale = AppSettings.AMLLLyricsRenderQuality(rawValue: value)?.renderScale ?? 0.75
                    NativeLyricsSurfaceManager.shared.setRenderScale(scale, for: role)
                }
            }
            .modifier(LyricsSettingsObserver(lyricsVM: lyricsVM, isActive: role == .main && isVisible))
            .onDisappear {
                NativeLyricsSurfaceManager.shared.clearSceneConfigurationOverride(for: role, owner: owner)
                // The returning inspector or fullscreen host owns teardown/activation.
                // An outgoing child must not deactivate a renderer its successor has mounted.
            }
    }

    private func synchronize() {
        if role == .main {
            LyricsSurfaceManager.shared.reportMainVisible(isVisible)
            if isVisible { lyricsVM.refreshConfigFromSettings() }
        } else if isVisible {
            NativeLyricsSurfaceManager.shared.activate(role: role)
        } else {
            NativeLyricsSurfaceManager.shared.deactivate(role: role)
        }
        NativeLyricsSurfaceManager.shared.setSeekHandler({ playback.seekAndResumeIfNeeded(to: $0) }, for: role)
        applyAuthorConfiguration()
    }

    private func applyAuthorConfiguration() {
        var values = configuration?.values ?? [:]
        if reduceMotion { values["enableSpring"] = .boolean(false) }
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8) else {
            NativeLyricsSurfaceManager.shared.setSceneConfigurationOverride(nil, for: role, owner: owner)
            return
        }
        NativeLyricsSurfaceManager.shared.setSceneConfigurationOverride(json, for: role, owner: owner)
    }
}
