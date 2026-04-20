//
//  FullscreenQuickAppearancePanel.swift
//  myPlayer2
//
//  kmgccc_player - Compact fullscreen appearance controls.
//

import AppKit
import SwiftUI

struct FullscreenQuickAppearancePanel: View {
    let glassStyle: FullscreenControlsGlassStyle
    let scale: CGFloat
    let onDismiss: () -> Void

    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var dismissRegistrationID: UUID?

    private static let cachedFontFamilies: [String] =
        NSFontManager.shared.availableFontFamilies.sorted()

    private let fontWeights: [(label: LocalizedStringKey, value: Int)] = [
        ("settings.lyrics.weight_thin", 100),
        ("settings.lyrics.weight_light", 300),
        ("settings.lyrics.weight_regular", 400),
        ("settings.lyrics.weight_medium", 500),
        ("settings.lyrics.weight_semibold", 600),
        ("settings.lyrics.weight_bold", 700),
    ]

    private var panelWidth: CGFloat { 500 * scale }
    private var panelHeight: CGFloat { 520 * scale }
    private var cornerRadius: CGFloat { 28 * scale }
    private var contentPadding: CGFloat { 20 * scale }
    private var sectionSpacing: CGFloat { 18 * scale }
    private var rowSpacing: CGFloat { 10 * scale }
    private var accentColor: Color {
        FullscreenMiniPlayerView.resolveControlPrimaryColor(from: themeStore.accentNSColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    skinSection
                    Divider().opacity(0.45)
                    lyricsTypographySection
                }
                .padding(.bottom, 2 * scale)
            }
        }
        .padding(contentPadding)
        .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
        .controlSize(.small)
        .liquidGlassRect(
            cornerRadius: cornerRadius,
            colorScheme: glassStyle.colorScheme,
            accentColor: glassStyle.accentColor,
            prominence: .prominent,
            materialStyle: glassStyle.materialStyle,
            isFloating: true
        )
        .environment(\.colorScheme, glassStyle.colorScheme)
        .onAppear(perform: registerDismissHandler)
        .onDisappear(perform: unregisterDismissHandler)
    }

    private var header: some View {
        HStack(spacing: 9 * scale) {
            Image(systemName: "paintpalette")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(accentColor)

            Text("快速外观")
                .font(.system(size: 15 * scale, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .frame(width: 24 * scale, height: 24 * scale)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭")
        }
    }

    private var skinSection: some View {
        VStack(alignment: .leading, spacing: 9 * scale) {
            sectionLabel("全屏皮肤")

            SkinSelectorRow(
                skins: SkinRegistry.fullscreenOptions,
                selectedSkinID: Binding(
                    get: { settings.fullscreen.skinID },
                    set: { settings.fullscreen.setSkinID($0) }
                ),
                cardSize: CGSize(width: 84 * scale, height: 98 * scale),
                previewSize: 56 * scale,
                cornerRadius: 10 * scale,
                titleFontSize: max(9, 10.5 * scale),
                itemSpacing: 8 * scale,
                edgePadding: 2 * scale,
                verticalPadding: 2 * scale
            )
            .frame(height: 108 * scale)
        }
    }

    private var lyricsTypographySection: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            sectionLabel("歌词字体")

            sliderRow(
                title: "主歌词字号",
                valueText: "\(Int(settings.fullscreenLyricsFontSize)) px",
                value: Binding(
                    get: { settings.fullscreenLyricsFontSize },
                    set: { settings.fullscreenLyricsFontSize = $0 }
                ),
                range: 24...72
            )

            pickerRow(title: "主歌词字重") {
                weightPicker(selection: Binding(
                    get: { settings.fullscreenLyricsFontWeight },
                    set: { settings.fullscreenLyricsFontWeight = $0 }
                ))
            }

            sliderRow(
                title: "翻译字号",
                valueText: "\(Int(settings.fullscreenLyricsTranslationFontSize)) px",
                value: Binding(
                    get: { settings.fullscreenLyricsTranslationFontSize },
                    set: { settings.fullscreenLyricsTranslationFontSize = $0 }
                ),
                range: 14...40
            )

            pickerRow(title: "翻译字重") {
                weightPicker(selection: Binding(
                    get: { settings.fullscreenLyricsTranslationFontWeight },
                    set: { settings.fullscreenLyricsTranslationFontWeight = $0 }
                ))
            }

            Divider().opacity(0.35)

            fontPickerRow(
                title: "中文字体",
                selection: Binding(
                    get: { settings.fullscreenLyricsFontNameZh },
                    set: { settings.fullscreenLyricsFontNameZh = $0 }
                )
            )

            fontPickerRow(
                title: "英文字体",
                selection: Binding(
                    get: { settings.fullscreenLyricsFontNameEn },
                    set: { settings.fullscreenLyricsFontNameEn = $0 }
                )
            )
        }
    }

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12 * scale, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func sliderRow(
        title: LocalizedStringKey,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack {
                Text(title)
                    .font(.system(size: 12 * scale, weight: .medium))
                Spacer()
                Text(valueText)
                    .font(.system(size: 11 * scale, weight: .medium, design: .monospaced))
                    .foregroundStyle(accentColor)
                    .monospacedDigit()
            }

            Slider(value: value, in: range, step: 1)
        }
    }

    private func pickerRow<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8 * scale) {
            Text(title)
                .font(.system(size: 12 * scale, weight: .medium))
            Spacer()
            content()
        }
    }

    private func weightPicker(selection: Binding<Int>) -> some View {
        Picker("", selection: selection) {
            ForEach(fontWeights, id: \.value) { weight in
                Text(weight.label).tag(weight.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 130 * scale)
    }

    private func fontPickerRow(title: LocalizedStringKey, selection: Binding<String>) -> some View {
        pickerRow(title: title) {
            Picker("", selection: selection) {
                ForEach(Self.cachedFontFamilies, id: \.self) { family in
                    Text(family)
                        .font(.custom(family, size: max(10, 11 * scale)))
                        .tag(family)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 210 * scale)
        }
    }

    private func registerDismissHandler() {
        guard dismissRegistrationID == nil else { return }
        dismissRegistrationID = FullscreenTransientDismissCoordinator.shared.register {
            onDismiss()
            return true
        }
    }

    private func unregisterDismissHandler() {
        guard let dismissRegistrationID else { return }
        FullscreenTransientDismissCoordinator.shared.unregister(dismissRegistrationID)
        self.dismissRegistrationID = nil
    }
}
