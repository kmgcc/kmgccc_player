//
//  LDDCSearchSection.swift
//  myPlayer2
//
//  kmgccc_player - LDDC Lyrics Search Section View
//  Embedded in TrackEditSheet for searching and applying lyrics.
//

import SwiftData
import SwiftUI

/// LDDC lyrics search section with Liquid Glass styling.
struct LDDCSearchSection: View {

    enum LayoutStyle {
        case stacked
        case split
    }

    let track: Track
    let layoutStyle: LayoutStyle
    let includeTranslationDefault: Bool
    let autoSearchToken: Int
    let onApplyTTML: (String) -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    // MARK: - State

    @State private var searchTitle = ""
    @State private var searchArtist = ""
    @State private var selectedMode: LDDCMode = .verbatim
    @State private var includeTranslation: Bool
    // Default platforms: QQ + Kugou + Netease (as requested).
    @State private var selectedSources: Set<LDDCSource> = [.QM, .KG, .NE]
    @State private var lastAutoSearchToken = 0

    @State private var isSearching = false
    @State private var searchResults: [LDDCCandidate] = []
    @State private var searchError: String?

    @State private var selectedCandidate: LDDCCandidate?
    @State private var isFetchingPreview = false
    @State private var previewLrcOrig: String?
    @State private var previewLrcTrans: String?
    @State private var editableLrcOrig = ""
    @State private var editableLrcTrans = ""
    @State private var previewError: String?

    @State private var isApplying = false
    @State private var applyError: String?
    @State private var stripExtraInfo = true

    private let client = LDDCClient()
    private let panelMaxWidth: CGFloat = 380
    private let visibleSources: [LDDCSource] = [.QM, .KG, .NE]

    init(
        track: Track,
        layoutStyle: LayoutStyle = .stacked,
        includeTranslationDefault: Bool = false,
        autoSearchToken: Int = 0,
        onApplyTTML: @escaping (String) -> Void
    ) {
        self.track = track
        self.layoutStyle = layoutStyle
        self.includeTranslationDefault = includeTranslationDefault
        self.autoSearchToken = autoSearchToken
        self.onApplyTTML = onApplyTTML
        _includeTranslation = State(initialValue: includeTranslationDefault)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            sectionHeader

            // Search Form
            searchFormSection

            if layoutStyle == .split {
                splitPanelSection
            } else {
                // Results List
                if !searchResults.isEmpty || isSearching {
                    resultsSection
                }

                // Preview Panel
                if selectedCandidate != nil {
                    previewSection
                }
            }

            // Error Display
            if let error = searchError ?? previewError ?? applyError {
                errorBanner(message: error)
            }
        }
        .onAppear {
            resetQueryForCurrentTrack()
            triggerAutoSearchIfNeeded(autoSearchToken, force: true)
        }
        .onChange(of: track.id) { _, _ in
            resetQueryForCurrentTrack()
        }
        .onChange(of: autoSearchToken) { _, newValue in
            triggerAutoSearchIfNeeded(newValue, force: false)
        }
    }

    // MARK: - Section Header

    private var sectionHeader: some View {
        HStack {
            Label(
                "search.lddc.title", systemImage: "magnifyingglass"
            )
            .font(.headline)

            Spacer()

            // Server status indicator
            if isSearching || isFetchingPreview || isApplying {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
    }

    // MARK: - Search Form

    private var searchFormSection: some View {
        VStack(spacing: 12) {
            // Title & Artist
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("search.lddc.song")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "search.lddc.song", text: $searchTitle
                    )
                    .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("search.lddc.artist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "search.lddc.artist", text: $searchArtist
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            // Mode & Translation
            HStack(spacing: 16) {
                // Mode Picker
                Picker("search.lddc.mode", selection: $selectedMode) {
                    ForEach(LDDCMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.displayName)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 150)

                // Translation Toggle
                Toggle(
                    "search.lddc.translation",
                    isOn: $includeTranslation
                )
                .toggleStyle(.switch)
                .tint(themeStore.accentColor)

                Spacer()
            }

            // Platform Selection
            HStack(spacing: 8) {
                Text("search.lddc.platform")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(visibleSources) { source in
                    Toggle(
                        source.displayName,
                        isOn: Binding(
                            get: { selectedSources.contains(source) },
                            set: { isOn in
                                if isOn {
                                    selectedSources.insert(source)
                                } else if selectedSources.count > 1 {
                                    selectedSources.remove(source)
                                }
                            }
                        )
                    )
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .tint(platformColor(source))
                }

                Spacer()

                // Search Button
                Button {
                    Task { await performSearch() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                        Text("search.lddc.search")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(searchTitle.isEmpty || isSearching)
            }
        }
    }

    // MARK: - Results Section

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("search.lddc.results_count \(searchResults.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(searchResults) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
            .frame(maxHeight: 340)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        // Keep this panel narrower and left-aligned so the right side stays free for
        // scrolling the outer sheet (avoids "mouse trapped inside inner scroll view").
        .frame(maxWidth: panelMaxWidth, alignment: .leading)
    }

    private var splitPanelSection: some View {
        HStack(alignment: .top, spacing: 16) {
            splitResultsSection
            splitPreviewSection
        }
        .frame(minHeight: 640)
    }

    private var splitResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("search.lddc.results_count \(searchResults.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Group {
                if isSearching {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("search.lddc.search")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 560)
                } else if searchResults.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text("请先搜索歌词候选，或切换到下一首触发自动查词。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 560)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(searchResults) { candidate in
                                candidateRow(candidate)
                            }
                        }
                    }
                    .frame(minHeight: 560)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func candidateRow(_ candidate: LDDCCandidate) -> some View {
        HStack(spacing: 8) {
            // Platform Badge
            Text(candidate.sourceEnum?.displayName ?? candidate.source)
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(platformColor(candidate.sourceEnum ?? .LRCLIB).opacity(0.2))
                .foregroundStyle(platformColor(candidate.sourceEnum ?? .LRCLIB))
                .clipShape(Capsule())

            // Score
            Text(String(format: "%.0f", candidate.score))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)

            // Title & Artist
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.subheadline)
                    .lineLimit(1)

                if let artist = candidate.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Selection indicator
            if selectedCandidate?.id == candidate.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(themeStore.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            selectedCandidate?.id == candidate.id
                ? themeStore.selectionFill
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await selectCandidate(candidate) }
        }
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("search.lddc.preview")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                if isFetchingPreview {
                    ProgressView()
                        .scaleEffect(0.6)
                }

                // Apply Button
                Button {
                    Task { await applyLyrics() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                        Text("search.lddc.apply")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(editableLrcOrig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isApplying)
            }

            Toggle("转换时去除多余信息", isOn: $stripExtraInfo)
                .toggleStyle(.switch)
                .tint(themeStore.accentColor)
                .font(.caption)

            Text("如果转换失败或删掉太多行，可以关闭此开关后手动编辑歌词。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("可直接编辑预览歌词，转换时将使用当前编辑内容。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Preview Tabs or single editor
            if includeTranslation && previewLrcTrans != nil {
                TabView {
                    previewEditorView(text: $editableLrcOrig)
                        .tabItem { Text("search.lddc.original") }

                    previewEditorView(text: $editableLrcTrans)
                        .tabItem { Text("search.lddc.translated") }
                }
                .frame(height: 320)
            } else {
                previewEditorView(text: $editableLrcOrig)
                    .frame(height: 320)
            }
        }
        .frame(maxWidth: panelMaxWidth, alignment: .leading)
    }

    private var splitPreviewSection: some View {
        Group {
            if selectedCandidate != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("search.lddc.preview")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if isFetchingPreview {
                            ProgressView()
                                .scaleEffect(0.6)
                        }

                        Button {
                            Task { await applyLyrics() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle")
                                Text("search.lddc.apply")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            editableLrcOrig.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty || isApplying
                        )
                    }

                    Toggle("转换时去除多余信息", isOn: $stripExtraInfo)
                        .toggleStyle(.switch)
                        .tint(themeStore.accentColor)
                        .font(.caption)

                    if includeTranslation && previewLrcTrans != nil {
                        TabView {
                            previewEditorView(text: $editableLrcOrig)
                                .tabItem { Text("search.lddc.original") }

                            previewEditorView(text: $editableLrcTrans)
                                .tabItem { Text("search.lddc.translated") }
                        }
                        .frame(minHeight: 560)
                    } else {
                        previewEditorView(text: $editableLrcOrig)
                            .frame(minHeight: 560)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(.secondary)
                    Text("从左侧选择候选后，可在这里预览、预编辑并转换成 TTML。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 560)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewEditorView(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Error Banner

    private func errorBanner(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer()
            Button("search.lddc.close") {
                searchError = nil
                previewError = nil
                applyError = nil
            }
            .font(.caption)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Actions

    private func resetQueryForCurrentTrack() {
        searchTitle = track.title
        searchArtist = track.artist
        selectedCandidate = nil
        previewLrcOrig = nil
        previewLrcTrans = nil
        editableLrcOrig = ""
        editableLrcTrans = ""
        searchError = nil
        previewError = nil
        applyError = nil
    }

    private func triggerAutoSearchIfNeeded(_ token: Int, force: Bool) {
        guard token > 0 else { return }
        if !force && token == lastAutoSearchToken {
            return
        }
        lastAutoSearchToken = token
        searchTitle = track.title
        searchArtist = track.artist
        includeTranslation = includeTranslationDefault
        Task { await performSearch() }
    }

    private func performSearch() async {
        guard !searchTitle.isEmpty else { return }

        isSearching = true
        searchError = nil
        searchResults = []
        selectedCandidate = nil
        previewLrcOrig = nil
        previewLrcTrans = nil
        editableLrcOrig = ""
        editableLrcTrans = ""

        do {
            let response = try await client.search(
                title: searchTitle,
                artist: searchArtist.isEmpty ? nil : searchArtist,
                sources: Array(selectedSources),
                mode: selectedMode,
                translation: includeTranslation
            )
            searchResults = response.results

            if let errors = response.errors, !errors.isEmpty {
                // Keep results visible; surface partial failures (e.g. NE blocked) for debugging.
                searchError = "search.lddc.partial_failed \(errors.joined(separator: "\n"))"
            } else if response.results.isEmpty {
                searchError = NSLocalizedString("search.lddc.not_found", comment: "")
            }
        } catch {
            searchError = error.localizedDescription
        }

        isSearching = false
    }

    private func selectCandidate(_ candidate: LDDCCandidate) async {
        selectedCandidate = candidate
        isFetchingPreview = true
        previewError = nil
        previewLrcOrig = nil
        previewLrcTrans = nil

        do {
            if includeTranslation {
                let (orig, trans) = try await client.fetchByIdSeparate(
                    candidate: candidate,
                    mode: selectedMode
                )
                previewLrcOrig = orig
                previewLrcTrans = trans
                editableLrcOrig = orig
                editableLrcTrans = trans ?? ""
            } else {
                let lrc = try await client.fetchById(
                    candidate: candidate,
                    mode: selectedMode,
                    translation: false
                )
                previewLrcOrig = lrc
                previewLrcTrans = nil
                editableLrcOrig = lrc
                editableLrcTrans = ""
            }
        } catch {
            previewError = error.localizedDescription
        }

        isFetchingPreview = false
    }

    private func applyLyrics() async {
        let origLrc = editableLrcOrig.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !origLrc.isEmpty else { return }

        isApplying = true
        applyError = nil

        do {
            let ttml: String

            if includeTranslation, previewLrcTrans != nil {
                ttml = try await TTMLConverter.shared.convertToTTMLWithTranslation(
                    origLrc: origLrc,
                    transLrc: editableLrcTrans,
                    stripMetadata: stripExtraInfo
                )
            } else {
                ttml = try await TTMLConverter.shared.convertToTTML(
                    lrc: origLrc,
                    stripMetadata: stripExtraInfo
                )
            }

            // Callback to parent to update track and UI
            onApplyTTML(ttml)

        } catch {
            applyError = error.localizedDescription
        }

        isApplying = false
    }

    // MARK: - Helpers

    private func platformColor(_ source: LDDCSource) -> Color {
        switch source {
        case .LRCLIB: return .blue
        case .QM: return .green
        case .KG: return .orange
        case .NE: return .red
        }
    }
}

// MARK: - Preview

#Preview("LDDC Search Section") {
    let track = Track(
        title: "守望者",
        artist: "司南",
        album: "Unknown",
        duration: 240,
        fileBookmarkData: Data()
    )

    ScrollView {
        LDDCSearchSection(track: track) { ttml in
            print("TTML applied: \(ttml.prefix(100))...")
        }
        .padding()
    }
    .environmentObject(ThemeStore.shared)
    .frame(width: 500, height: 600)
}
