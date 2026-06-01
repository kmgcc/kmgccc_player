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

    @State private var globalArtworkTintEnabled: Bool = AppSettings.shared.globalArtworkTintEnabled
    @State private var dockProgressVisible: Bool = AppSettings.shared.dockProgressVisible
    @State private var followSystemAppearance: Bool = AppSettings.shared.followSystemAppearance
    @State private var lyricsBackgroundMode: AppSettings.LyricsBackgroundMode = AppSettings.shared.lyricsBackgroundMode
    @State private var homeCardMaterialMode: AppSettings.HomeCardMaterialMode = AppSettings.shared.homeCardMaterialMode
    @State private var homeSectionOrder: [HomeSection] = AppSettings.shared.homeSectionOrder
    @State private var draggedHomeSection: HomeSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("外观", systemImage: "paintpalette")

            SettingsSection {
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

            VStack(spacing: 6) {
                ForEach(homeSectionOrder) { section in
                    homeSectionOrderRow(section)
                        .onDrag {
                            draggedHomeSection = section
                            return NSItemProvider(object: section.rawValue as NSString)
                        }
                        .onDrop(
                            of: [UTType.plainText],
                            delegate: HomeSectionOrderDropDelegate(
                                targetSection: section,
                                sectionOrder: $homeSectionOrder,
                                draggedSection: $draggedHomeSection,
                                onCommit: saveHomeSectionOrder
                            )
                        )
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )

            Button("恢复默认顺序") {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    homeSectionOrder = HomeSection.defaultOrder
                }
                saveHomeSectionOrder(homeSectionOrder)
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
        }
    }

    private func homeSectionOrderRow(_ section: HomeSection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(themeStore.accentColor)
                .frame(width: 18)

            Text(section.title)
                .settingsRowLabelStyle()

            Spacer(minLength: 12)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .help("拖动调整顺序")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground(for: section))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func rowBackground(for section: HomeSection) -> Color {
        draggedHomeSection == section
            ? themeStore.accentColor.opacity(0.10)
            : Color.primary.opacity(0.035)
    }

    private func saveHomeSectionOrder(_ order: [HomeSection]) {
        settings.homeSectionOrder = order
    }
}

private struct HomeSectionOrderDropDelegate: DropDelegate {
    let targetSection: HomeSection
    @Binding var sectionOrder: [HomeSection]
    @Binding var draggedSection: HomeSection?
    let onCommit: ([HomeSection]) -> Void

    func dropEntered(info: DropInfo) {
        guard
            let draggedSection,
            draggedSection != targetSection,
            let fromIndex = sectionOrder.firstIndex(of: draggedSection),
            let toIndex = sectionOrder.firstIndex(of: targetSection)
        else {
            return
        }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
            sectionOrder.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
        onCommit(sectionOrder)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        onCommit(sectionOrder)
        draggedSection = nil
        return true
    }
}
