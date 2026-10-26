//
//  TrackInfoEditorComponents.swift
//  myPlayer2
//
//  Tabs and settings-style sections shared by the song-info editor, the
//  external playback override editor, the batch editor's middle column and
//  the album and artist editors.
//

import SwiftUI

/// A page of a tabbed info editor popup.
protocol InfoEditorTab: Hashable, Identifiable {
    var title: String { get }
}

nonisolated enum TrackInfoEditorTab: Int, CaseIterable, Identifiable, InfoEditorTab {
    case artworkAndBasics
    case details
    case lyrics

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .artworkAndBasics: "封面与基础"
        case .details: "更多信息"
        case .lyrics: "歌词"
        }
    }
}

enum TrackInfoEditorLayout {
    /// Inner scroll areas stop short of the trailing edge; the pointer over
    /// that strip scrolls the page instead of the inner list.
    static let scrollGutter: CGFloat = 64
    static let fieldLabelWidth: CGFloat = 76
    static let rowSpacing: CGFloat = 10
    static let pageBottomRoom: CGFloat = 24
}

extension View {
    /// Leading-aligned inner scroll area with a free trailing gutter.
    func trackInfoInnerScrollArea() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, TrackInfoEditorLayout.scrollGutter)
    }

    /// Settings typography, foreground palette and section cards for editor
    /// forms hosted inside popups.
    func trackInfoEditorSettingsStyle() -> some View {
        modifier(TrackInfoEditorSettingsStyle())
    }
}

private struct TrackInfoEditorSettingsStyle: ViewModifier {
    @EnvironmentObject private var themeStore: ThemeStore

    func body(content: Content) -> some View {
        let palette = themeStore.appForegroundPalette
        content
            .groupBoxStyle(SettingsWindowGroupBoxStyle())
            .environment(\.fullscreenSettingsPresentationStyle, .settingsWindow)
            .environment(
                \.settingsAppForegroundColors,
                SettingsAppForegroundColors(
                    primary: palette.primaryColor,
                    secondary: palette.secondaryColor,
                    tertiary: palette.tertiaryColor,
                    quaternary: palette.quaternaryColor,
                    disabled: palette.disabledColor
                )
            )
    }
}

// MARK: - Tabs

struct TrackInfoEditorTabBar<Tab: InfoEditorTab>: View {
    let tabs: [Tab]
    @Binding var selection: Tab

    /// The selector reads a local index, so releasing a drag moves the knob
    /// and the selection in one update. Read through the owner's binding, the
    /// selection can arrive a pass later inside a split view, and the knob
    /// overshoots by the drag distance before springing back.
    @State private var index: Int

    init(tabs: [Tab], selection: Binding<Tab>) {
        self.tabs = tabs
        _selection = selection
        _index = State(initialValue: tabs.firstIndex(of: selection.wrappedValue) ?? 0)
    }

    var body: some View {
        SettingsTabSelector(tabs: tabs.map(\.title), selectedTab: $index, fillsWidth: true)
            .onChange(of: index) { _, newValue in
                guard tabs.indices.contains(newValue), tabs[newValue] != selection else { return }
                selection = tabs[newValue]
            }
            .onChange(of: selection) { _, newValue in
                let resolved = tabs.firstIndex(of: newValue) ?? 0
                if resolved != index { index = resolved }
            }
    }
}

/// Builds a page on its first visit and keeps it afterwards, so search
/// results and scroll positions held in page state survive tab switches.
struct TrackInfoEditorTabPages<Tab: InfoEditorTab, Page: View>: View {
    let tabs: [Tab]
    let selection: Tab
    private let page: (Tab) -> Page

    @State private var visited: Set<Tab> = []

    init(
        tabs: [Tab],
        selection: Tab,
        @ViewBuilder page: @escaping (Tab) -> Page
    ) {
        self.tabs = tabs
        self.selection = selection
        self.page = page
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(tabs) { tab in
                if tab == selection || visited.contains(tab) {
                    let isSelected = tab == selection
                    page(tab)
                        .frame(maxWidth: .infinity, maxHeight: isSelected ? .infinity : 0, alignment: .top)
                        .clipped()
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { visited.insert(selection) }
        .onChange(of: selection) { _, newValue in
            visited.insert(newValue)
        }
    }
}

// MARK: - Rows

struct TrackInfoFieldRow: View {
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey
    @Binding var text: String

    init(_ title: LocalizedStringKey, prompt: LocalizedStringKey = "", text: Binding<String>) {
        self.title = title
        self.prompt = prompt
        self._text = text
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .settingsRowLabelStyle()
                .frame(width: TrackInfoEditorLayout.fieldLabelWidth, alignment: .leading)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct TrackInfoValueRow: View {
    let title: LocalizedStringKey
    let value: String

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    init(_ title: LocalizedStringKey, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .settingsRowLabelStyle()
            Spacer(minLength: 12)
            Text(displayValue)
                .font(.system(size: presentationStyle.rowValueFontSize))
                .foregroundStyle(presentationStyle.settingsSecondaryTextColor(appColors: appColors))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var displayValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未记录" : value
    }
}

/// Multi-line editor on the popup's content tint, kept clear of the trailing gutter.
struct TrackInfoTextEditorBox: View {
    let prompt: LocalizedStringKey?
    @Binding var text: String
    var height: CGFloat
    var monospaced = false
    var reservesScrollGutter = true

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    var body: some View {
        let editor = ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(editorFont)
                .lineSpacing(monospaced ? 2 : 4)
                .padding(8)
                .scrollContentBackground(.hidden)

            if let prompt, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(prompt)
                    .font(.system(size: presentationStyle.rowFontSize))
                    .foregroundStyle(presentationStyle.settingsTertiaryTextColor(appColors: appColors))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .appPopupContentBackground()
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        if reservesScrollGutter {
            editor.trackInfoInnerScrollArea()
        } else {
            editor
        }
    }

    private var editorFont: Font {
        monospaced
            ? .system(size: 12, design: .monospaced)
            : .system(size: presentationStyle.rowFontSize)
    }
}

// MARK: - Sections

struct TrackInfoArtworkSection<Preview: View, Extra: View>: View {
    let coordinator: CoverSearchCoordinator?
    let hasArtwork: Bool
    let allowsImport: Bool
    let onChooseImage: () -> Void
    let onFetchCover: () -> Void
    let onRemoveArtwork: () -> Void
    let onSelectCandidate: (CoverCandidate) -> Void
    private let preview: Preview
    private let extra: Extra

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    init(
        coordinator: CoverSearchCoordinator?,
        hasArtwork: Bool,
        allowsImport: Bool,
        onChooseImage: @escaping () -> Void,
        onFetchCover: @escaping () -> Void,
        onRemoveArtwork: @escaping () -> Void,
        onSelectCandidate: @escaping (CoverCandidate) -> Void,
        @ViewBuilder preview: () -> Preview,
        @ViewBuilder extra: () -> Extra
    ) {
        self.coordinator = coordinator
        self.hasArtwork = hasArtwork
        self.allowsImport = allowsImport
        self.onChooseImage = onChooseImage
        self.onFetchCover = onFetchCover
        self.onRemoveArtwork = onRemoveArtwork
        self.onSelectCandidate = onSelectCandidate
        self.preview = preview()
        self.extra = extra()
    }

    var body: some View {
        SettingsSection("封面") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    ZStack {
                        preview
                        if coordinator?.isLoading == true {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                                .background(.regularMaterial)
                                .clipShape(Circle())
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if allowsImport {
                            Button(LocalizedStringKey("edit.track.choose_image"), action: onChooseImage)
                        }
                        Button("查找封面", action: onFetchCover)
                            .disabled(coordinator?.isLoading == true)
                        if hasArtwork {
                            Button(LocalizedStringKey("edit.track.remove_artwork"), role: .destructive, action: onRemoveArtwork)
                        }
                    }
                    .buttonStyle(AppPanelButtonStyle())
                    .font(.system(size: presentationStyle.rowFontSize, weight: .medium))

                    if let coordinator, coordinator.hasCandidates {
                        CoverCandidateStripView(
                            candidates: coordinator.candidates,
                            selectedCandidate: coordinator.selectedForPreview,
                            onSelect: onSelectCandidate
                        )
                    }
                }

                if let error = coordinator?.error {
                    Text(error)
                        .font(presentationStyle.captionFont)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                extra
            }
        }
    }
}

extension TrackInfoArtworkSection where Extra == EmptyView {
    init(
        coordinator: CoverSearchCoordinator?,
        hasArtwork: Bool,
        allowsImport: Bool,
        onChooseImage: @escaping () -> Void,
        onFetchCover: @escaping () -> Void,
        onRemoveArtwork: @escaping () -> Void,
        onSelectCandidate: @escaping (CoverCandidate) -> Void,
        @ViewBuilder preview: () -> Preview
    ) {
        self.init(
            coordinator: coordinator,
            hasArtwork: hasArtwork,
            allowsImport: allowsImport,
            onChooseImage: onChooseImage,
            onFetchCover: onFetchCover,
            onRemoveArtwork: onRemoveArtwork,
            onSelectCandidate: onSelectCandidate,
            preview: preview,
            extra: { EmptyView() }
        )
    }
}

struct TrackInfoBasicsSection: View {
    @Binding var title: String
    @Binding var artist: String
    @Binding var album: String
    let duration: Double?

    var body: some View {
        SettingsSection("基础信息") {
            VStack(alignment: .leading, spacing: TrackInfoEditorLayout.rowSpacing) {
                TrackInfoFieldRow("edit.track.track_title", prompt: "edit.track.track_title", text: $title)
                TrackInfoFieldRow("edit.track.artist", prompt: "edit.track.artist_name", text: $artist)
                TrackInfoFieldRow("edit.track.album", prompt: "edit.track.album_name", text: $album)
                if let duration {
                    Divider()
                    TrackInfoValueRow("edit.track.duration", value: Self.formatDuration(duration))
                }
            }
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct TrackInfoDescriptionSection: View {
    @Binding var text: String
    let albumDescription: String?

    var body: some View {
        SettingsSection("edit.track.description") {
            VStack(alignment: .leading, spacing: 10) {
                TrackInfoTextEditorBox(
                    prompt: "edit.track.description_placeholder",
                    text: $text,
                    height: 132
                )

                if let albumDescription = trimmedAlbumDescription,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("来自专辑介绍")
                            .settingsRowLabelStyle()
                        Text(albumDescription)
                            .settingsDescriptionStyle()
                            .lineLimit(3)
                    }
                    .trackInfoInnerScrollArea()
                }
            }
        }
    }

    private var trimmedAlbumDescription: String? {
        guard let albumDescription else { return nil }
        let trimmed = albumDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct TrackInfoMetadataLookupSection: View {
    let isLookupInFlight: Bool
    let message: String?
    let candidates: [QQMusicArtworkCandidate]
    let selectedSongMid: String
    let onFetch: () -> Void
    let onSelect: (QQMusicArtworkCandidate) -> Void

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    var body: some View {
        SettingsSection("在线匹配", info: "联网查找这首歌，补全专辑、介绍、流派与发行信息。") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button(action: onFetch) {
                        Label("查找元数据", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(AppPanelButtonStyle())
                    .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                    .disabled(isLookupInFlight)

                    if isLookupInFlight {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let message {
                        Text(message)
                            .settingsDescriptionStyle()
                    }
                }

                if !candidates.isEmpty {
                    MetadataCandidateStripView(
                        candidates: candidates,
                        selectedSongMid: selectedSongMid,
                        onSelect: onSelect
                    )
                }
            }
        }
    }
}

struct TrackInfoDetailFieldsSection: View {
    @Binding var genreTagsText: String
    @Binding var releaseDateText: String
    @Binding var language: String
    @Binding var labelOrCompany: String

    var body: some View {
        SettingsSection("详细信息") {
            VStack(alignment: .leading, spacing: TrackInfoEditorLayout.rowSpacing) {
                TrackInfoFieldRow("流派 / 标签", prompt: "用逗号分隔", text: $genreTagsText)
                TrackInfoFieldRow("发行日期", prompt: "YYYY-MM-DD", text: $releaseDateText)
                TrackInfoFieldRow("语言", text: $language)
                TrackInfoFieldRow("厂牌 / 公司", text: $labelOrCompany)
            }
        }
    }
}

struct TrackInfoMetadataRecordSection: View {
    let songMid: String
    let source: String
    let fetchedAt: Date?
    let confidence: Double?

    var body: some View {
        SettingsSection("来源记录") {
            VStack(alignment: .leading, spacing: 8) {
                TrackInfoValueRow("QQ 音乐 Song MID", value: songMid)
                TrackInfoValueRow("来源", value: source)
                TrackInfoValueRow("获取时间", value: fetchedAt.map(Self.formatDate) ?? "")
                TrackInfoValueRow("置信度", value: confidence.map { String(format: "%.2f", $0) } ?? "")
            }
        }
    }

    private static func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct TrackInfoLyricsEditorSection: View {
    @Binding var lyricsText: String
    let validationMessage: String?
    let onImport: () -> Void
    let onClear: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    private static let amllDbURL = URL(string: "https://github.com/amll-dev/amll-ttml-db")!
    private static let ttmlToolURL = URL(string: "https://amll-ttml-tool.stevexmh.net/")!

    var body: some View {
        SettingsSection(
            "edit.track.lyrics",
            info: "AMLL DB 的 TTML 歌词为 AMLL 设计，支持对唱与背景人声；网络转换的歌词只作缺失时的备选。也可以用 AMLL TTML Tool 制作歌词，自用或贡献给 AMLL DB。",
            headerTrailing: {
                HStack(spacing: 6) {
                    Button {
                        openURL(Self.amllDbURL)
                    } label: {
                        Label("AMLL DB", systemImage: "arrow.up.right.square")
                    }
                    Button {
                        openURL(Self.ttmlToolURL)
                    } label: {
                        Label("TTML Tool", systemImage: "hammer.fill")
                    }
                }
                .buttonStyle(AppPanelButtonStyle())
                .font(.system(size: presentationStyle.captionFontSize, weight: .medium))
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TrackInfoTextEditorBox(
                    prompt: "edit.track.paste_desc",
                    text: $lyricsText,
                    height: 220,
                    monospaced: true
                )

                if let validationMessage {
                    Text(validationMessage)
                        .font(presentationStyle.captionFont)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("导入歌词文件…", action: onImport)
                    if let onClear {
                        Button("清除歌词", role: .destructive, action: onClear)
                            .disabled(lyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .buttonStyle(AppPanelButtonStyle())
                .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
            }
        }
    }
}

struct TrackInfoLyricsOffsetSection: View {
    @Binding var offsetMs: Double

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    /// The slider covers common corrections; a typed or scrubbed value may go
    /// up to the ±15 s the lyrics renderer honours.
    private static let sliderRange: ClosedRange<Double> = -5...5
    private static let freeRange: ClosedRange<Double> = -15...15

    var body: some View {
        SettingsSection("edit.track.offset", info: NSLocalizedString("edit.track.offset_desc", comment: "")) {
            HStack(spacing: 12) {
                Slider(value: sliderSeconds, in: Self.sliderRange)
                ScrubbableNumberField(
                    value: seconds,
                    range: Self.sliderRange,
                    step: 0.05,
                    unit: "s",
                    fractionDigits: 2,
                    freeRange: Self.freeRange
                )
                .frame(width: DSPRangeSliderRow.valueWidth + 8, alignment: .trailing)
                .accessibilityLabel(Text("edit.track.offset"))
                Button(LocalizedStringKey("edit.track.reset")) {
                    offsetMs = 0
                }
                .buttonStyle(AppPanelButtonStyle())
                .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                .disabled(offsetMs == 0)
            }
        }
    }

    private var seconds: Binding<Double> {
        Binding(get: { offsetMs / 1000 }, set: { offsetMs = ($0 * 1000).rounded() })
    }

    /// Snaps to 0.1 s; a value beyond the slider shows at its end without being clamped.
    private var sliderSeconds: Binding<Double> {
        Binding(
            get: { min(max(offsetMs / 1000, Self.sliderRange.lowerBound), Self.sliderRange.upperBound) },
            set: { offsetMs = ($0 * 10).rounded() * 100 }
        )
    }
}
