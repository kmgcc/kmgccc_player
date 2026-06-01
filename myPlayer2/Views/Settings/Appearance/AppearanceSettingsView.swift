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
    //
    // Two invariants make the drag stable:
    //  1. Floating position is anchored to `dragStartIndex` (captured once) plus
    //     the live gesture translation — it never reads the live array index, so
    //     reordering the array cannot feed back into the pill's position.
    //  2. The gesture is measured in a container-fixed *named* coordinate space,
    //     so when a reorder slides the dragged row to a new slot the translation
    //     stays continuous (a `.local` space would jump by one slot and jitter).
    @State private var draggingSection: HomeSection?
    @State private var dragStartIndex: Int = 0
    @State private var dragLastTargetIndex: Int = 0
    @State private var dragFloatingX: CGFloat = 0
    @State private var dragFloatingY: CGFloat = 0
    @State private var dragContainerWidth: CGFloat = 0
    @State private var isFinishingDrag = false

    private let homeRowHeight: CGFloat = 40
    private let homeRowSpacing: CGFloat = 6
    // Center-to-center distance between adjacent rows; the unit of vertical
    // travel for both floating position and reorder stepping.
    private var homeRowStride: CGFloat { homeRowHeight + homeRowSpacing }
    // Fixed reference frame for the drag gesture — does not move when rows reorder.
    private let homeReorderSpace = "homeSectionReorderSpace"

    // Horizontal follow is damped and capped so the pill leans toward the
    // cursor without flying off; it is purely cosmetic and never feeds reorder.
    private let dragHorizontalDamping: CGFloat = 0.45
    private let dragHorizontalLimit: CGFloat = 28

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
            //
            // The reorder `move` is wrapped in its own withAnimation, so only the
            // neighbour rows / placeholder reflow with a spring. We deliberately
            // do NOT put a container-wide `.animation(value: homeSectionOrder)`
            // here: that would also try to animate the floating overlay's offset
            // every frame and fight the gesture, causing the up/down jitter.
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
            // Fixed coordinate space so the gesture translation stays continuous
            // even as rows reorder underneath the finger.
            .coordinateSpace(name: homeReorderSpace)
            // Custom floating overlay drawn by us — never the system drag image.
            // Its offset is driven straight from gesture translation (no implicit
            // animation), so it tracks the cursor 1:1.
            .overlay(alignment: .top) {
                if let dragging = draggingSection {
                    homeSectionOrderFloatingRow(dragging)
                        .frame(width: dragContainerWidth, height: homeRowHeight)
                        .offset(x: dragFloatingX, y: dragFloatingY)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Spacer(minLength: 0)

                Button("恢复默认顺序") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        homeSectionOrder = HomeSection.defaultOrder
                        draggingSection = nil
                        isFinishingDrag = false
                        dragFloatingX = 0
                    }
                    saveHomeSectionOrder(homeSectionOrder)
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
            }
        }
    }

    // The row is a STABLE ZStack whose view identity never changes during a
    // drag. We only cross-fade the inner content vs. placeholder via opacity —
    // we never swap one view subtree for a different one. Swapping subtrees
    // (the old `if/else`) re-created the view the gesture was attached to on the
    // first frame, which made macOS drop the in-flight drag (the "grab twice"
    // bug). Keeping identity stable lets the very first grab track immediately.
    private func homeSectionOrderRow(_ section: HomeSection) -> some View {
        let isDragging = draggingSection == section
        return ZStack {
            homeSectionOrderPlaceholder()
                .opacity(isDragging ? 1 : 0)
            homeSectionOrderRowContent(section)
                .opacity(isDragging ? 0 : 1)
        }
        .frame(height: homeRowHeight)
        .contentShape(Capsule())
        // The opacity flip is intentionally NOT animated: `draggingSection` is
        // assigned outside `withAnimation`, so the content↔placeholder swap is
        // instant (no first-frame fade that would delay the grab). Row position
        // reflow still animates, because that comes from the `move` wrapped in
        // withAnimation below.
        // High priority so a row drag reliably starts the reorder instead of
        // losing the gesture race to the enclosing settings ScrollView.
        .highPriorityGesture(reorderGesture(for: section))
    }

    private func reorderGesture(for section: HomeSection) -> some Gesture {
        // minimumDistance 2 distinguishes a drag from a click. The gesture is
        // measured in the container-fixed named space so translation never jumps
        // when rows reorder beneath the finger.
        DragGesture(minimumDistance: 2, coordinateSpace: .named(homeReorderSpace))
            .onChanged { value in
                if draggingSection != section {
                    // Capture the launch slot ONCE. Everything below is derived
                    // from this fixed anchor + live translation; we never refresh
                    // it from the (now-moving) live array index.
                    let start = homeSectionOrder.firstIndex(of: section) ?? 0
                    draggingSection = section
                    dragStartIndex = start
                    dragLastTargetIndex = start
                    isFinishingDrag = false
                }

                // Floating pill: y is anchored to the launch slot + finger
                // travel (decoupled from the array). x leans toward the cursor
                // with damping + a cap. Both assigned outside any animation so
                // the pill is exactly 1:1 with the cursor.
                dragFloatingY = CGFloat(dragStartIndex) * homeRowStride + value.translation.height
                dragFloatingX = max(
                    -dragHorizontalLimit,
                    min(dragHorizontalLimit, value.translation.width * dragHorizontalDamping)
                )

                // Reorder target from the pill's CENTER y (vertical only — the
                // horizontal lean can never affect ordering).
                let centerY = dragFloatingY + homeRowHeight / 2
                let target = max(0, min(homeSectionOrder.count - 1,
                                        Int((centerY / homeRowStride).rounded(.down))))

                // Hysteresis: only react when the target slot actually changes.
                // This stops the order from oscillating when the pill hovers near
                // a row mid-line (the up/down twitch).
                guard target != dragLastTargetIndex else { return }
                dragLastTargetIndex = target

                guard let current = homeSectionOrder.firstIndex(of: section),
                      current != target else { return }

                // Animate ONLY the reorder, so neighbours slide while the pill
                // keeps tracking the cursor without any animation interference.
                withAnimation(.snappy(duration: 0.16)) {
                    homeSectionOrder.move(
                        fromOffsets: IndexSet(integer: current),
                        toOffset: target > current ? target + 1 : target
                    )
                }
            }
            .onEnded { _ in
                // Persist once at the end (not per onChanged) to avoid hammering
                // UserDefaults.
                saveHomeSectionOrder(homeSectionOrder)

                // Settle the floating pill onto its final slot (x → 0, y → final
                // row origin) before the real row reappears, so there is no pop.
                let finalIndex = homeSectionOrder.firstIndex(of: section) ?? dragStartIndex
                isFinishingDrag = true
                withAnimation(.snappy(duration: 0.16)) {
                    dragFloatingX = 0
                    dragFloatingY = CGFloat(finalIndex) * homeRowStride
                }

                // Clear only after the settle animation, and only if a new drag
                // has not taken over in the meantime (token guards against the
                // stale async callback wiping a fresh drag).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    guard isFinishingDrag, draggingSection == section else { return }
                    draggingSection = nil
                    isFinishingDrag = false
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
