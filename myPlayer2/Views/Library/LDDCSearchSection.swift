//
//  LDDCSearchSection.swift
//  myPlayer2
//
//  kmgccc_player - LDDC Lyrics Search Section View
//  Embedded in TrackEditSheet for searching and applying lyrics.
//

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
    let onApplyLyrics: (String) -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    // MARK: - State

    @State private var searchTitle = ""
    @State private var searchArtist = ""
    @State private var selectedMode: LDDCMode = .verbatim
    @State private var includeTranslation: Bool
    // Default platforms: QQ + Kugou + Netease + AMLLDB.
    @State private var selectedSources: Set<LDDCSource> = [.QM, .KG, .NE, .AMLLDB]
    @State private var lastAutoSearchToken = 0

    @State private var isSearching = false
    @State private var searchResults: [LDDCCandidate] = []
    @State private var searchError: String?

    @State private var selectedCandidate: LDDCCandidate?
    @State private var isFetchingPreview = false
    @State private var previewOrig: String?
    @State private var previewTrans: String?
    @State private var editableOrig = ""
    @State private var editableTrans = ""
    @State private var previewError: String?

    @State private var isApplying = false
    @State private var applyError: String?
    @State private var stripExtraInfo = false

    private let client = LDDCClient()
    private let amlldbService = AMLLDBService.shared
    private let panelMaxWidth: CGFloat = 380
    private let visibleSources: [LDDCSource] = [.QM, .KG, .NE, .AMLLDB]

    init(
        track: Track,
        layoutStyle: LayoutStyle = .stacked,
        includeTranslationDefault: Bool = true,
        autoSearchToken: Int = 0,
        onApplyLyrics: @escaping (String) -> Void
    ) {
        self.track = track
        self.layoutStyle = layoutStyle
        self.includeTranslationDefault = includeTranslationDefault
        self.autoSearchToken = autoSearchToken
        self.onApplyLyrics = onApplyLyrics
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
                "LDDC 歌词搜索", systemImage: "magnifyingglass"
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
                    Text("歌曲名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "歌曲名", text: $searchTitle
                    )
                    .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("歌手")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "歌手", text: $searchArtist
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            // Mode & Translation
            HStack(spacing: 12) {
                // Mode Picker - Pill Style
                HStack(spacing: 4) {
                    Text("模式")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 4) {
                        ForEach(LDDCMode.allCases) { mode in
                            Button {
                                selectedMode = mode
                            } label: {
                                Text(mode.displayName)
                                    .font(.system(size: 11, weight: selectedMode == mode ? .medium : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .background(
                                Capsule()
                                    .fill(selectedMode == mode ? themeStore.accentColor.opacity(0.18) : Color.clear)
                            )
                            .foregroundStyle(selectedMode == mode ? themeStore.accentColor : .secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.08))
                    )
                }

                // Translation Toggle - Pill Style
                HStack(spacing: 4) {
                    Text("翻译")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 4) {
                        ForEach([true, false], id: \.self) { enabled in
                            Button {
                                includeTranslation = enabled
                            } label: {
                                Text(enabled ? "开" : "关")
                                    .font(.system(size: 11, weight: includeTranslation == enabled ? .medium : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .background(
                                Capsule()
                                    .fill(includeTranslation == enabled ? themeStore.accentColor.opacity(0.18) : Color.clear)
                            )
                            .foregroundStyle(includeTranslation == enabled ? themeStore.accentColor : .secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.08))
                    )
                }

                Spacer()
            }

            // Platform Selection
            HStack(spacing: 12) {
                Text("平台")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
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
                        .clipShape(Capsule())
                    }
                }

                Spacer()

                // Search Button
                Button {
                    Task { await performSearch() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                        Text("搜索")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(searchTitle.isEmpty || isSearching)
                .clipShape(Capsule())
            }
        }
    }

    // MARK: - Results Section

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("搜索结果：\(searchResults.count)")
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
        HSplitView {
            splitResultsSection
                .frame(minWidth: 170, idealWidth: 240, maxWidth: 320)
                .clipped()
            splitPreviewSection
                .frame(minWidth: 300, idealWidth: 520, maxWidth: .infinity)
                .clipped()
        }
        .frame(minHeight: 640)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var splitResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("搜索结果：\(searchResults.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Group {
                if isSearching {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("搜索中…")
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
                .background(platformColor(candidate.sourceEnum ?? .QM).opacity(0.2))
                .foregroundStyle(platformColor(candidate.sourceEnum ?? .QM))
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
                Text("预览")
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
                        Text("应用")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(editableOrig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isApplying)
                .clipShape(Capsule())
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
            if includeTranslation && previewTrans != nil {
                TabView {
                    previewEditorView(text: $editableOrig)
                        .tabItem { Text("原文") }

                    previewEditorView(text: $editableTrans)
                        .tabItem { Text("翻译") }
                }
                .frame(height: 320)
            } else {
                previewEditorView(text: $editableOrig)
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
                        Text("预览")
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
                                Text("应用")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            editableOrig.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty || isApplying
                        )
                        .clipShape(Capsule())
                    }

                    Toggle("转换时去除多余信息", isOn: $stripExtraInfo)
                        .toggleStyle(.switch)
                        .tint(themeStore.accentColor)
                        .font(.caption)

                    if includeTranslation && previewTrans != nil {
                        TabView {
                            previewEditorView(text: $editableOrig)
                                .tabItem { Text("原文") }

                            previewEditorView(text: $editableTrans)
                                .tabItem { Text("翻译") }
                        }
                        .frame(minHeight: 560)
                    } else {
                        previewEditorView(text: $editableOrig)
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
            Button("关闭") {
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
        previewOrig = nil
        previewTrans = nil
        editableOrig = ""
        editableTrans = ""
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
        previewOrig = nil
        previewTrans = nil
        editableOrig = ""
        editableTrans = ""

        do {
            // Check and update AMLLDB index if needed (on first search)
            if selectedSources.contains(.AMLLDB) {
                _ = await amlldbService.checkAndUpdateIfNeeded()
            }
            
            // Perform LDDC and AMLLDB searches in parallel
            async let lddcTask: LDDCSearchResponse? = performLDDCSearch()
            async let amlldbTask: [LDDCCandidate] = performAMLLDBSearch()
            
            let lddcResponse = await lddcTask
            let amlldbResults = await amlldbTask
            
            // Merge results
            var allResults: [LDDCCandidate] = []
            if let lddc = lddcResponse {
                allResults.append(contentsOf: lddc.results)
            }
            allResults.append(contentsOf: amlldbResults)
            
            // Sort by score descending
            allResults.sort { $0.score > $1.score }
            
            searchResults = allResults
            
            if searchResults.isEmpty {
                searchError = "未找到可用歌词"
            }
        } catch {
            searchError = error.localizedDescription
        }

        isSearching = false
    }
    
    private func performLDDCSearch() async -> LDDCSearchResponse? {
        let lddcSources = selectedSources.filter { $0 != .AMLLDB }
        guard !lddcSources.isEmpty else { return nil }
        
        do {
            return try await client.search(
                title: searchTitle,
                artist: searchArtist.isEmpty ? nil : searchArtist,
                sources: Array(lddcSources),
                mode: selectedMode,
                translation: includeTranslation
            )
        } catch {
            return nil
        }
    }
    
    private func performAMLLDBSearch() async -> [LDDCCandidate] {
        guard selectedSources.contains(.AMLLDB) else { return [] }
        
        let results = amlldbService.search(
            title: searchTitle,
            artist: searchArtist.isEmpty ? nil : searchArtist,
            limit: 20
        )
        
        return results.map { $0.toLDDCCandidate() }
    }

    private func selectCandidate(_ candidate: LDDCCandidate) async {
        selectedCandidate = candidate
        isFetchingPreview = true
        previewError = nil
        previewOrig = nil
        previewTrans = nil

        do {
            if candidate.source == "AMLLDB" {
                // AMLLDB: Direct TTML download, no conversion needed
                let ttml = try await amlldbService.downloadLyrics(ncmMusicId: candidate.songId)
                previewOrig = ttml
                previewTrans = nil
                editableOrig = ttml
                editableTrans = ""
            } else if includeTranslation {
                let (orig, trans) = try await client.fetchByIdSeparate(
                    candidate: candidate,
                    mode: selectedMode
                )
                previewOrig = orig
                previewTrans = trans
                editableOrig = orig
                editableTrans = trans ?? ""
            } else {
                let lyrics = try await client.fetchById(
                    candidate: candidate,
                    mode: selectedMode,
                    translation: false
                )
                previewOrig = lyrics
                previewTrans = nil
                editableOrig = lyrics
                editableTrans = ""
            }
        } catch {
            previewError = error.localizedDescription
        }

        isFetchingPreview = false
    }

    private func applyLyrics() async {
        let origLyrics = editableOrig.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !origLyrics.isEmpty else { return }

        isApplying = true
        applyError = nil

        do {
            let ttml: String
            
            // Check if this is an AMLLDB result (already TTML format)
            if selectedCandidate?.source == "AMLLDB" {
                // AMLLDB lyrics are already in TTML format
                ttml = origLyrics
            } else if includeTranslation, previewTrans != nil {
                ttml = try await TTMLConverter.shared.convertToTTMLWithTranslation(
                    origLyrics: origLyrics,
                    transLyrics: editableTrans,
                    stripMetadata: stripExtraInfo
                )
            } else {
                ttml = try await TTMLConverter.shared.convertToTTML(
                    rawLyrics: origLyrics,
                    stripMetadata: stripExtraInfo
                )
            }

            onApplyLyrics(ttml)

        } catch {
            applyError = error.localizedDescription
        }

        isApplying = false
    }

    // MARK: - Helpers

    private func platformColor(_ source: LDDCSource) -> Color {
        switch source {
        case .QM: return .green
        case .KG: return .orange
        case .NE: return .red
        case .LRCLIB: return .blue
        case .AMLLDB: return .purple
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