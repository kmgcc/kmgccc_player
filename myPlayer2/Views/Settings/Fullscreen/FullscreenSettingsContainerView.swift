//
//  FullscreenSettingsContainerView.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Playback Settings with Tab Navigation
//

import SwiftUI

struct FullscreenSettingsPresentationStyle: Equatable {
    let fullscreenScale: CGFloat
    let isCompact: Bool
    let forcesWhiteText: Bool
    let usesGlassSectionCards: Bool
    let usesMaterialSectionCards: Bool
    let glassMaterialStyle: LiquidGlassPillMaterialStyle
    let controlSize: ControlSize
    let panelSize: CGSize
    let panelCornerRadius: CGFloat
    let panelContentPadding: CGFloat
    let panelBottomPadding: CGFloat
    let closeButtonSize: CGFloat
    let containerSpacing: CGFloat
    let contentSpacing: CGFloat
    let groupPadding: CGFloat
    let groupSpacing: CGFloat
    let sectionSpacing: CGFloat
    let sectionCornerRadius: CGFloat
    let sectionLabelSpacing: CGFloat
    let scrollContentBottomPadding: CGFloat
    let headerIconSize: CGFloat
    let headerTitleFontSize: CGFloat
    let headerBottomPadding: CGFloat
    let tabFontSize: CGFloat
    let tabMinWidth: CGFloat
    let tabHeight: CGFloat
    let tabHorizontalPadding: CGFloat
    let tabVerticalPadding: CGFloat
    let tabTrackHorizontalPadding: CGFloat
    let tabTrackVerticalPadding: CGFloat
    let sectionTitleFontSize: CGFloat
    let rowFontSize: CGFloat
    let rowValueFontSize: CGFloat
    let captionFontSize: CGFloat
    let compactInlineSpacing: CGFloat
    let rowSpacing: CGFloat
    let sliderBlockSpacing: CGFloat
    let sliderCaptionSpacing: CGFloat
    let dividerVerticalPadding: CGFloat
    let pickerWidth: CGFloat
    let compactPickerWidth: CGFloat
    let segmentedFontSize: CGFloat
    let segmentedHorizontalPadding: CGFloat
    let segmentedVerticalPadding: CGFloat
    let segmentedTrackHorizontalPadding: CGFloat
    let segmentedTrackVerticalPadding: CGFloat
    let skinCardSize: CGSize
    let skinPreviewSize: CGFloat
    let skinCornerRadius: CGFloat
    let skinTitleFontSize: CGFloat
    let skinItemSpacing: CGFloat
    let skinEdgePadding: CGFloat
    let skinVerticalPadding: CGFloat
    let skinContentInset: CGFloat
    let skinContentHorizontalPadding: CGFloat
    let skinContentVerticalPadding: CGFloat
    let skinContentSpacing: CGFloat
    let skinTitleMinHeight: CGFloat

    static let settingsWindow = FullscreenSettingsPresentationStyle(
        fullscreenScale: 1,
        isCompact: false,
        forcesWhiteText: false,
        usesGlassSectionCards: false,
        usesMaterialSectionCards: false,
        glassMaterialStyle: .clear,
        controlSize: .regular,
        panelSize: CGSize(width: 660, height: 760),
        panelCornerRadius: 28,
        panelContentPadding: 20,
        panelBottomPadding: 16,
        closeButtonSize: 28,
        containerSpacing: 20,
        contentSpacing: 20,
        groupPadding: SettingsStyleTokens.groupPadding,
        groupSpacing: SettingsStyleTokens.groupSpacing,
        sectionSpacing: SettingsStyleTokens.sectionSpacing,
        sectionCornerRadius: SettingsStyleTokens.sectionCornerRadius,
        sectionLabelSpacing: 10,
        scrollContentBottomPadding: 0,
        headerIconSize: 20,
        headerTitleFontSize: 30,
        headerBottomPadding: 4,
        tabFontSize: 13,
        tabMinWidth: 72,
        tabHeight: 26,
        tabHorizontalPadding: 0,
        tabVerticalPadding: 4,
        tabTrackHorizontalPadding: 4,
        tabTrackVerticalPadding: 2,
        sectionTitleFontSize: SettingsStyleTokens.sectionTitleFontSize,
        rowFontSize: SettingsStyleTokens.rowFontSize,
        rowValueFontSize: SettingsStyleTokens.rowValueFontSize,
        captionFontSize: SettingsStyleTokens.descriptionFontSize,
        compactInlineSpacing: SettingsStyleTokens.inlineSpacing,
        rowSpacing: 8,
        sliderBlockSpacing: 8,
        sliderCaptionSpacing: 6,
        dividerVerticalPadding: 4,
        pickerWidth: 220,
        compactPickerWidth: 140,
        segmentedFontSize: 11,
        segmentedHorizontalPadding: 10,
        segmentedVerticalPadding: 4,
        segmentedTrackHorizontalPadding: 4,
        segmentedTrackVerticalPadding: 3,
        skinCardSize: CGSize(width: 104, height: 124),
        skinPreviewSize: 80,
        skinCornerRadius: 12,
        skinTitleFontSize: 11,
        skinItemSpacing: 10,
        skinEdgePadding: 10,
        skinVerticalPadding: 4,
        skinContentInset: 4,
        skinContentHorizontalPadding: 8,
        skinContentVerticalPadding: 10,
        skinContentSpacing: 8,
        skinTitleMinHeight: 16
    )

    static func fullscreenOverlay(
        scale: CGFloat
    ) -> FullscreenSettingsPresentationStyle {
        FullscreenSettingsPresentationStyle(
            fullscreenScale: scale,
            isCompact: true,
            // Quick panel readability is built around a white-text hierarchy.
            forcesWhiteText: true,
            usesGlassSectionCards: false,
            usesMaterialSectionCards: true,
            glassMaterialStyle: .clear,
            // Keep quick panel compact; specifically shrinks .switch toggles without
            // changing the material hierarchy.
            controlSize: .regular,
            // Narrower + slightly shorter to stay out of the Mini Player's way.
            panelSize: CGSize(width: 560 * scale, height: 690 * scale),
            panelCornerRadius: 30 * scale,
            panelContentPadding: 20 * scale,
            panelBottomPadding: 16 * scale,
            closeButtonSize: 30 * scale,
            containerSpacing: 12 * scale,
            contentSpacing: 12 * scale,
            // Slightly larger horizontal padding inside each section for stability.
            groupPadding: 14 * scale,
            groupSpacing: 10 * scale,
            sectionSpacing: 10 * scale,
            sectionCornerRadius: 18 * scale,
            sectionLabelSpacing: 8 * scale,
            scrollContentBottomPadding: 12 * scale,
            headerIconSize: 18 * scale,
            headerTitleFontSize: 22 * scale,
            headerBottomPadding: 2 * scale,
            tabFontSize: 13.0 * scale,
            tabMinWidth: 96 * scale,
            tabHeight: 30 * scale,
            tabHorizontalPadding: 0,
            tabVerticalPadding: 4 * scale,
            tabTrackHorizontalPadding: 5 * scale,
            tabTrackVerticalPadding: 2 * scale,
            sectionTitleFontSize: 14 * scale,
            rowFontSize: 13.5 * scale,
            rowValueFontSize: 13 * scale,
            captionFontSize: 11.5 * scale,
            compactInlineSpacing: 10 * scale,
            rowSpacing: 8 * scale,
            sliderBlockSpacing: 7 * scale,
            sliderCaptionSpacing: 4 * scale,
            dividerVerticalPadding: 3 * scale,
            pickerWidth: 250 * scale,
            compactPickerWidth: 158 * scale,
            segmentedFontSize: 12.5 * scale,
            segmentedHorizontalPadding: 12 * scale,
            segmentedVerticalPadding: 5 * scale,
            segmentedTrackHorizontalPadding: 5 * scale,
            segmentedTrackVerticalPadding: 4 * scale,
            skinCardSize: CGSize(width: 122 * scale, height: 136 * scale),
            skinPreviewSize: 84 * scale,
            skinCornerRadius: 14 * scale,
            skinTitleFontSize: 12 * scale,
            skinItemSpacing: 10 * scale,
            skinEdgePadding: 8 * scale,
            skinVerticalPadding: 2 * scale,
            skinContentInset: 5 * scale,
            skinContentHorizontalPadding: 10 * scale,
            skinContentVerticalPadding: 11 * scale,
            skinContentSpacing: 8 * scale,
            skinTitleMinHeight: 18 * scale
        )
    }

    var sectionTitleFont: Font {
        .system(size: sectionTitleFontSize, weight: .semibold)
    }

    var rowLabelFont: Font {
        .system(size: rowFontSize, weight: .medium)
    }

    var rowValueFont: Font {
        .system(size: rowValueFontSize, weight: .medium, design: .monospaced)
    }

    var captionFont: Font {
        .system(size: captionFontSize)
    }

    var tabLabelFont: Font {
        .system(size: tabFontSize, weight: .medium)
    }

    var segmentedLabelFont: Font {
        .system(size: segmentedFontSize, weight: .regular)
    }

    var primaryTextColor: Color {
        forcesWhiteText ? Color.white.opacity(0.98) : .primary
    }

    var secondaryTextColor: Color {
        forcesWhiteText ? Color.white.opacity(0.88) : .secondary
    }

    var tertiaryTextColor: Color {
        forcesWhiteText ? Color.white.opacity(0.74) : Color.secondary.opacity(0.78)
    }

    var segmentedTrackColor: Color {
        // Quick panel runs in a light hierarchy, but the capsule tracks should stay neutral-dark
        // so they read consistently on top of ultraThinMaterial section surfaces.
        if usesMaterialSectionCards {
            return Color.white.opacity(0.12)
        }
        return forcesWhiteText ? Color.white.opacity(0.08) : Color.secondary.opacity(0.08)
    }

    var segmentedTrackStrokeColor: Color {
        if usesMaterialSectionCards {
            return Color.white.opacity(0.16)
        }
        return .clear
    }

    func selectedTextColor(accentColor: Color) -> Color {
        forcesWhiteText ? primaryTextColor : accentColor
    }

    func valueTextColor(accentColor: Color) -> Color {
        forcesWhiteText ? primaryTextColor : accentColor
    }

    func skinTitleColor(selected: Bool, accentColor: Color, colorScheme: ColorScheme) -> Color {
        if forcesWhiteText {
            return selected ? primaryTextColor : secondaryTextColor
        }
        return selected ? accentColor : Color.primary.opacity(colorScheme == .dark ? 0.72 : 0.70)
    }
}

private struct FullscreenSettingsGlassGroupBoxStyle: GroupBoxStyle {
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: presentationStyle.sectionLabelSpacing) {
            configuration.label
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: presentationStyle.sectionCornerRadius,
                style: .continuous
            )
            .fill(Color.clear)
        )
        .liquidGlassRect(
            cornerRadius: presentationStyle.sectionCornerRadius,
            colorScheme: colorScheme,
            accentColor: nil,
            prominence: .standard,
            materialStyle: presentationStyle.glassMaterialStyle,
            isFloating: false
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: presentationStyle.sectionCornerRadius,
                style: .continuous
            )
            .fill(Color.white.opacity(presentationStyle.forcesWhiteText ? 0.018 : 0.01))
            .allowsHitTesting(false)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: presentationStyle.sectionCornerRadius,
                style: .continuous
            )
        )
    }
}

private struct FullscreenSettingsMaterialGroupBoxStyle: GroupBoxStyle {
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: presentationStyle.sectionLabelSpacing) {
            configuration.label
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: presentationStyle.sectionCornerRadius,
                style: .continuous
            )
            .fill(.ultraThinMaterial)
            .overlay(
                // Light ultraThinMaterial can be too bright against white text; add a tiny tint
                // without changing the material type.
                RoundedRectangle(
                    cornerRadius: presentationStyle.sectionCornerRadius,
                    style: .continuous
                )
                .fill(Color.black.opacity(0.06))
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: presentationStyle.sectionCornerRadius,
                style: .continuous
            )
            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            .allowsHitTesting(false)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: presentationStyle.sectionCornerRadius,
                style: .continuous
            )
        )
    }
}

private struct FullscreenSettingsPresentationStyleKey: EnvironmentKey {
    static let defaultValue = FullscreenSettingsPresentationStyle.settingsWindow
}

extension EnvironmentValues {
    var fullscreenSettingsPresentationStyle: FullscreenSettingsPresentationStyle {
        get { self[FullscreenSettingsPresentationStyleKey.self] }
        set { self[FullscreenSettingsPresentationStyleKey.self] = newValue }
    }
}

/// Container view for Fullscreen settings with "皮肤" and "歌词" tabs.
struct FullscreenSettingsContainerView: View {
    @EnvironmentObject private var themeStore: ThemeStore

    let presentationStyle: FullscreenSettingsPresentationStyle
    let embedsScrollView: Bool

    @State private var selectedTab = 0
    private let tabs = ["皮肤", "歌词", "LED"]

    init(
        presentationStyle: FullscreenSettingsPresentationStyle = .settingsWindow,
        embedsScrollView: Bool = false
    ) {
        self.presentationStyle = presentationStyle
        self.embedsScrollView = embedsScrollView
    }

    var body: some View {
        Group {
            if presentationStyle.usesGlassSectionCards {
                containerBody
                    .groupBoxStyle(FullscreenSettingsGlassGroupBoxStyle())
            } else if presentationStyle.usesMaterialSectionCards {
                containerBody
                    .groupBoxStyle(FullscreenSettingsMaterialGroupBoxStyle())
            } else {
                containerBody
            }
        }
    }

    private var containerBody: some View {
        VStack(alignment: .leading, spacing: presentationStyle.containerSpacing) {
            SettingsHeaderLabel("全屏播放", systemImage: "arrow.up.left.and.arrow.down.right")

            SettingsTabSelector(tabs: tabs, selectedTab: $selectedTab, fillsWidth: true)

            if embedsScrollView {
                ScrollView(.vertical, showsIndicators: false) {
                    tabContent
                        .padding(.bottom, presentationStyle.scrollContentBottomPadding)
                }
            } else {
                tabContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(presentationStyle.primaryTextColor)
        .tint(themeStore.accentColor)
        .controlSize(presentationStyle.controlSize)
        .environment(\.fullscreenSettingsPresentationStyle, presentationStyle)
        .environmentObject(themeStore)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case 0:
            FullscreenSkinTabView()
        case 1:
            FullscreenLyricsTabView()
        case 2:
            LEDMeterSettingsView(showTitle: false)
        default:
            FullscreenSkinTabView()
        }
    }
}
