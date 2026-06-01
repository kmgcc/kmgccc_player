//
//  AppearanceSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - Appearance Settings View
//

import SwiftUI
import UniformTypeIdentifiers

/// Appearance settings: global tint, system appearance, lyrics background mode.
struct AppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var globalArtworkTintEnabled: Bool = AppSettings.shared.globalArtworkTintEnabled
    @State private var dockProgressVisible: Bool = AppSettings.shared.dockProgressVisible
    @State private var followSystemAppearance: Bool = AppSettings.shared.followSystemAppearance
    @State private var lyricsBackgroundMode: AppSettings.LyricsBackgroundMode = AppSettings.shared.lyricsBackgroundMode
    @State private var homeCardMaterialMode: AppSettings.HomeCardMaterialMode = AppSettings.shared.homeCardMaterialMode
    @State private var homeSectionOrder: [HomeSection] = AppSettings.shared.homeSectionOrder

    // Custom drag-reorder state (no system drag preview).
    @State private var draggingSection: HomeSection?
    @State private var dragFloatingY: CGFloat = 0
    @State private var dragContainerWidth: CGFloat = 0

    private let homeRowHeight: CGFloat = 40
    private let homeRowSpacing: CGFloat = 6
    private let homeReorderSpace = "homeSectionReorderSpace"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("外观", systemImage: "paintpalette")

            SettingsSection("常规") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsSwitchRow(
                        title: "全局取色",
                        isOn: $globalArtworkTintEnabled,
                        detail: "开启后重点色跟随当前歌曲封面，关闭后使用默认主题色。"
                    )

                    SettingsSwitchRow(
                        title: "Dock 播放进度",
                        isOn: $dockProgressVisible,
                        detail: "开启后 Dock 图标底部显示当前歌曲进度"
                    )

                    SettingsSwitchRow(
                        title: "深色/浅色跟随系统",
                        isOn: $followSystemAppearance,
                        detail: "开启后跟随系统深浅色，关闭后可用侧边栏按钮手动切换深/浅。"
                    )

                    Divider()

                    lyricsBackgroundModePicker

                    homeCardMaterialModePicker
                }
            }

            SettingsSection("主页板块顺序") {
                homeSectionOrderEditor
            }
        }
        .onAppear {
            globalArtworkTintEnabled = settings.globalArtworkTintEnabled
            dockProgressVisible = settings.dockProgressVisible
            followSystemAppearance = settings.followSystemAppearance
            lyricsBackgroundMode = settings.lyricsBackgroundMode
            homeCardMaterialMode = settings.homeCardMaterialMode
            homeSectionOrder = settings.homeSectionOrder
        }
        .onChange(of: globalArtworkTintEnabled) { _, newValue in
            settings.globalArtworkTintEnabled = newValue
            Task { @MainActor in
                await themeStore.refreshPalette(reason: "settings_global_tint_change")
            }
        }
        .onChange(of: dockProgressVisible) { _, newValue in
            settings.dockProgressVisible = newValue
        }
        .onChange(of: followSystemAppearance) { _, newValue in
            settings.followSystemAppearance = newValue
        }
        .onChange(of: lyricsBackgroundMode) { _, newValue in
            settings.lyricsBackgroundMode = newValue
        }
        .onChange(of: homeCardMaterialMode) { _, newValue in
            settings.homeCardMaterialMode = newValue
        }
        .onChange(of: settings.homeSectionOrder) { _, newValue in
            guard newValue != homeSectionOrder else { return }
            homeSectionOrder = newValue
        }
    }

    private var lyricsBackgroundModePicker: some View {
        HStack(spacing: 8) {
            Text("歌词卡片背景")
                .settingsRowLabelStyle()

            Spacer()

            SlidingSelector(
                segments: AppSettings.LyricsBackgroundMode.allCases,
                selection: $lyricsBackgroundMode,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(themeStore.accentColor.opacity(0.18))
                },
                content: { mode, isSelected in
                    Text(mode.title)
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? themeStore.accentColor : .secondary)
                }
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var homeCardMaterialModePicker: some View {
        HStack(spacing: 8) {
            Text("主页卡片材质")
                .settingsRowLabelStyle()

            Spacer()

            SlidingSelector(
                segments: AppSettings.HomeCardMaterialMode.allCases,
                selection: $homeCardMaterialMode,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(themeStore.accentColor.opacity(0.18))
                },
                content: { mode, isSelected in
                    Text(mode.title)
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? themeStore.accentColor : .secondary)
                }
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var homeSectionOrderEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("拖动调整主页中各个板块的显示顺序。")
                .settingsDescriptionStyle()

            // No inner list-level background container: each row carries its
            // own pill, the surrounding SettingsSection already provides chrome.
            VStack(spacing: homeRowSpacing) {
                ForEach(homeSectionOrder) { section in
                    homeSectionOrderRow(section)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { dragContainerWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in
                            dragContainerWidth = newValue
                        }
                }
            )
            .coordinateSpace(name: homeReorderSpace)
            // Custom floating overlay drawn by us — never the system drag image.
            .overlay(alignment: .top) {
                if let dragging = draggingSection {
                    homeSectionOrderFloatingRow(dragging)
                        .frame(width: dragContainerWidth, height: homeRowHeight)
                        .offset(y: dragFloatingY)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Spacer(minLength: 0)

                Button("恢复默认顺序") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        homeSectionOrder = HomeSection.defaultOrder
                        draggingSection = nil
                    }
                    saveHomeSectionOrder(homeSectionOrder)
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
            }
        }
    }

    // Each row keeps the SAME footprint in every state (normal / placeholder /
    // floating), so nothing jumps on grab or release. The dragged row is
    // branched purely by `draggingSection` identity, never by opacity alone.
    @ViewBuilder
    private func homeSectionOrderRow(_ section: HomeSection) -> some View {
        Group {
            if draggingSection == section {
                homeSectionOrderPlaceholder()
            } else {
                homeSectionOrderRowContent(section)
            }
        }
        .frame(height: homeRowHeight)
        .gesture(reorderGesture(for: section))
    }

    private func reorderGesture(for section: HomeSection) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(homeReorderSpace))
            .onChanged { value in
                if draggingSection != section {
                    draggingSection = section
                }
                // Floating row follows the finger directly (no animation), and
                // stays full row width — no system preview shrinking.
                dragFloatingY = value.location.y - homeRowHeight / 2

                let stride = homeRowHeight + homeRowSpacing
                let proposed = Int((value.location.y / stride).rounded(.down))
                let target = max(0, min(homeSectionOrder.count - 1, proposed))

                guard let current = homeSectionOrder.firstIndex(of: section),
                      current != target else { return }

                // Reorder live as the row crosses neighbour mid-lines, so the
                // list reflows under the finger instead of waiting for drop.
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    homeSectionOrder.move(
                        fromOffsets: IndexSet(integer: current),
                        toOffset: target > current ? target + 1 : target
                    )
                }
            }
            .onEnded { _ in
                saveHomeSectionOrder(homeSectionOrder)
                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                    draggingSection = nil
                }
            }
    }

    private func homeSectionOrderRowContent(_ section: HomeSection) -> some View {
        homeSectionRowLayout(section, handleColor: .tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                Capsule()
                    .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
    }

    private func homeSectionOrderPlaceholder() -> some View {
        Capsule()
            .fill(Color.secondary.opacity(0.035))
            .overlay(
                Capsule()
                    .strokeBorder(
                        Color.secondary.opacity(0.12),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 6])
                    )
            )
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
    }

    // Custom clear-glass floating pill. Full width, stable size, readable text.
    private func homeSectionOrderFloatingRow(_ section: HomeSection) -> some View {
        homeSectionRowLayout(section, handleColor: .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassPill(
                colorScheme: colorScheme,
                accentColor: themeStore.accentColor,
                prominence: .prominent,
                materialStyle: .clear,
                isFloating: true
            )
    }

    // Shared row layout so normal / floating rows are pixel-identical.
    private func homeSectionRowLayout(
        _ section: HomeSection,
        handleColor: HierarchicalShapeStyle
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(themeStore.accentColor)
                .frame(width: 20)

            Text(section.title)
                .settingsRowLabelStyle()

            Spacer(minLength: 16)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(handleColor)
                .frame(width: 28)
                .help("拖动调整顺序")
        }
        .padding(.horizontal, 16)
        .frame(height: homeRowHeight)
    }

    private func saveHomeSectionOrder(_ order: [HomeSection]) {
        settings.homeSectionOrder = order
    }
}
