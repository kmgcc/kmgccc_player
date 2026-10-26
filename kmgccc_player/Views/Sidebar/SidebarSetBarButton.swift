import MotionKit
import SwiftUI

/// Shared by the live bar, the editor and the floating drag image.
@MainActor
struct SidebarSetBarButton: View {
    let kind: SidebarSetBarItemKind
    var isSegment = false
    var showsHelp = true
    let action: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(UIStateViewModel.self) private var uiState: UIStateViewModel?
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var isOn: Bool? {
        switch kind {
        case .soundEffects: return appSession.audioDSPController.configuration.enabled
        case .externalPlayback: return settings.showPlaybackSourceSwitcher
        case .backgroundPreparation: return settings.backgroundPreparationEnabled
        case .latencyCompensation: return settings.audioLookaheadEnabled
        case .hdr: return settings.audioVisualizationHDREnabled
        case .motionArtwork: return settings.motionArtworkEnabled
        case .systemAppearance: return settings.followSystemAppearance
        case .lyrics:
            guard let uiState else { return nil }
            return uiState.usesSkinScene ? uiState.skinSceneLyricsVisible : uiState.lyricsVisible
        default: return nil
        }
    }

    private var systemImage: String {
        switch kind {
        case .volumeTarget:
            return settings.volumeControlTarget == .app ? "slider.horizontal.3" : "speaker.wave.2"
        case .soundEffects:
            return isOn == true ? "waveform" : "waveform.slash"
        case .externalPlayback:
            return isOn == true ? "music.note.tv" : "music.note"
        case .backgroundPreparation:
            return isOn == true ? "clock.arrow.circlepath" : "clock"
        case .latencyCompensation:
            return isOn == true ? "waveform.path" : "waveform"
        case .motionArtwork:
            return isOn == true ? "livephoto" : "livephoto.slash"
        case .systemAppearance:
            return isOn == true
                ? "circle.lefthalf.filled"
                : (settings.resolvedColorScheme == .dark ? "moon" : "sun.max")
        case .lyrics:
            return isOn == true ? "quote.bubble.fill" : "quote.bubble"
        default:
            return kind.systemImage(isDark: settings.resolvedColorScheme == .dark)
        }
    }

    private var accessibilityValue: Text {
        if kind == .volumeTarget {
            return Text(settings.volumeControlTarget.title)
        }
        return isOn.map { $0 ? Text("开启") : Text("关闭") } ?? Text("")
    }

    var body: some View {
        Group {
            if kind == .separator {
                Button(action: action) {
                    Rectangle()
                        .fill(themeStore.accentColor)
                        .frame(width: 1.5, height: 14)
                        .frame(width: GlassStyleTokens.headerControlHeight, height: GlassStyleTokens.headerControlHeight)
                        .liquidGlassCircle(colorScheme: colorScheme)
                }
                .buttonStyle(.plain)
            } else {
                GlassIconButton(
                    systemImage: systemImage,
                    size: GlassStyleTokens.headerControlHeight,
                    iconSize: 14,
                    isPrimary: kind == .appearance || isOn == true,
                    iconColorOverride: isOn == false ? themeStore.appForegroundPalette.secondaryColor : nil,
                    help: showsHelp ? LocalizedStringKey(kind.title) : nil,
                    surfaceVariant: isSegment ? .sidebarBottom : .defaultToolbar,
                    action: action
                )
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                )
                .motionAnimation(.microInteraction, value: systemImage)
            }
        }
        .accessibilityLabel(Text(kind.title))
        .accessibilityValue(accessibilityValue)
    }
}

@MainActor
struct SidebarSetBarHoverableButton<Content: View>: View {
    let kind: SidebarSetBarItemKind
    private let content: Content
    @State private var isHovered = false
    @State private var hoverDelayTask: Task<Void, Never>?

    init(kind: SidebarSetBarItemKind, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.content = content()
    }

    var body: some View {
        content
            .overlay(alignment: .top) {
                if isHovered {
                    SidebarSetBarHoverStatus(kind: kind)
                        .offset(y: -26)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                        .zIndex(1)
                }
            }
            .zIndex(isHovered ? 1 : 0)
            .onHover(perform: updateHoverState)
            .onDisappear {
                hoverDelayTask?.cancel()
                hoverDelayTask = nil
                isHovered = false
            }
            .motionAnimation(.microInteraction, value: isHovered)
    }

    private func updateHoverState(_ hovering: Bool) {
        hoverDelayTask?.cancel()
        hoverDelayTask = nil

        guard hovering else {
            isHovered = false
            return
        }
        guard !isHovered else { return }

        hoverDelayTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            isHovered = true
            hoverDelayTask = nil
        }
    }
}

@MainActor
private struct SidebarSetBarHoverStatus: View {
    let kind: SidebarSetBarItemKind

    @Environment(AppSettings.self) private var settings
    @Environment(UIStateViewModel.self) private var uiState: UIStateViewModel?
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var fullscreenManager = FullscreenWindowManager.shared

    private var enabledState: Bool? {
        switch kind {
        case .soundEffects: return appSession.audioDSPController.configuration.enabled
        case .externalPlayback: return settings.showPlaybackSourceSwitcher
        case .backgroundPreparation: return settings.backgroundPreparationEnabled
        case .latencyCompensation: return settings.audioLookaheadEnabled
        case .hdr: return settings.audioVisualizationHDREnabled
        case .motionArtwork: return settings.motionArtworkEnabled
        case .systemAppearance: return settings.followSystemAppearance
        case .lyrics:
            guard let uiState else { return nil }
            return uiState.usesSkinScene ? uiState.skinSceneLyricsVisible : uiState.lyricsVisible
        default: return nil
        }
    }

    private var statusText: String {
        switch kind {
        case .settings: return "打开设置"
        case .appearance: return settings.resolvedColorScheme == .dark ? "当前深色外观" : "当前浅色外观"
        case .fullscreen: return fullscreenManager.isFullscreenPlayerPresented ? "退出全屏" : "进入全屏"
        case .volumeTarget: return settings.volumeControlTarget.title
        case .separator: return "按钮分组"
        case .soundEffects: return "音效处理已\(enabledState == true ? "开启" : "关闭")"
        case .externalPlayback: return "从外部播放已\(enabledState == true ? "开启" : "关闭")"
        case .backgroundPreparation: return "空闲时提前准备已\(enabledState == true ? "开启" : "关闭")"
        case .latencyCompensation: return "延迟补偿已\(enabledState == true ? "开启" : "关闭")"
        case .hdr: return "HDR 效果已\(enabledState == true ? "开启" : "关闭")"
        case .motionArtwork: return "动态封面已\(enabledState == true ? "开启" : "关闭")"
        case .systemAppearance: return "跟随系统外观已\(enabledState == true ? "开启" : "关闭")"
        case .lyrics:
            guard let enabledState else { return "歌词" }
            return enabledState ? "歌词已显示" : "歌词已隐藏"
        }
    }

    var body: some View {
        Text(statusText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .liquidGlassPill(
                colorScheme: colorScheme,
                materialStyle: .regular,
                isFloating: true
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
