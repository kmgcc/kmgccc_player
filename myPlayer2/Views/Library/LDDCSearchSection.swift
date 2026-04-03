//
//  LDDCSearchSection.swift
//  myPlayer2
//
//  kmgccc_player - LDDC Lyrics Search Section View
//  Embedded in TrackEditSheet for searching and applying lyrics.
//

import SwiftUI
import os.log

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
    @Environment(\.modelContext) private var modelContext
    
    // MARK: - Logger
    private static let logger = Logger(subsystem: "com.kmgccc.player", category: "LyricsSearch")
    
    // MARK: - State
    
    @State private var searchTitle = ""
    @State private var searchArtist = ""
    @State private var searchAlbum = ""
    @State private var selectedMode: LDDCMode = .verbatim
    @State private var includeTranslation: Bool
    
    // LDDC platforms (separate from AMLLDB)
    @State private var selectedLDDCSources: Set<LDDCSource> = [.QM, .KG, .NE]
    // AMLLDB is always enabled
    @State private var enableAMLLDB = true
    
    @State private var lastAutoSearchToken = 0
    
    @State private var isSearching = false
    @State private var searchResults: [LDDCCandidate] = []
    @State private var searchError: String?
    
    // Separate results for display
    @State private var amlldbResults: [LDDCCandidate] = []
    @State private var lddcResults: [LDDCCandidate] = []
    
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
    
    // Index update state
    @State private var isUpdatingAMLLDBIndex = false
    @State private var amlldbIndexStatus: String? = nil
    
    private let client = LDDCClient()
    private let amlldbService = AMLLDBService.shared
    private let panelMaxWidth: CGFloat = 380
    private let visibleLDDCSources: [LDDCSource] = [.QM, .KG, .NE]
    
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
            
            // AMLLDB Index Status
            if let status = amlldbIndexStatus {
                amlldbStatusBanner(status: status)
            }
            
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
            // Setup AMLLDB model context
            amlldbService.setupModelContext(modelContext)
            Self.logger.info("[LyricsSearch] View appeared, AMLLDB model context set")
            
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
    
    // MARK: - AMLLDB Status Banner
    
    private func amlldbStatusBanner(status: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
            Text(status)
                .font(.caption)
            if isUpdatingAMLLDBIndex {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    // MARK: - Section Header
    
    private var sectionHeader: some View {
        HStack {
            Label(
                "歌词搜索", systemImage: "magnifyingglass"
            )
            .font(.headline)
            
            Spacer()
            
            // Server status indicator
            if isSearching || isFetchingPreview || isApplying || isUpdatingAMLLDBIndex {
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
            
            // Mode Selection (LDDC only)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("模式")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 8) {
                        ForEach(LDDCMode.allCases) { mode in
                            Button {
                                selectedMode = mode
                            } label: {
                                Text(mode.displayName)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedMode == mode ? .accentColor : .secondary)
                            .clipShape(Capsule())
                        }
                    }
                }
                
                // Translation Toggle (LDDC only)
                VStack(alignment: .leading, spacing: 4) {
                    Text("翻译")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Toggle("包含翻译", isOn: $includeTranslation)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                Spacer()
            }
            
            // Platform Selection
            HStack(spacing: 12) {
                Text("平台")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                // AMLLDB Toggle (separate from LDDC)
                Toggle(
                    "AMLL 歌词库",
                    isOn: $enableAMLLDB
                )
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(enableAMLLDB ? .purple : .secondary)
                .clipShape(Capsule())
                
                // LDDC Platforms
                HStack(spacing: 8) {
                    ForEach(visibleLDDCSources) { source in
                        Toggle(
                            source.displayName,
                            isOn: Binding(
                                get: { selectedLDDCSources.contains(source) },
                                set: { isOn in
                                    if isOn {
                                        selectedLDDCSources.insert(source)
                                    } else if selectedLDDCSources.count > 1 {
                                        selectedLDDCSources.remove(source)
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
            // Results Summary
            HStack {
                Text("搜索结果：\(searchResults.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                if amlldbResults.count > 0 {
                    Text("(AMLLDB: \(amlldbResults.count))")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                
                if lddcResults.count > 0 {
                    Text("(LDDC: \(lddcResults.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            
            ScrollView {
                LazyVStack(spacing: 4) {
                    // AMLLDB Results Section Header
                    if !amlldbResults.isEmpty {
                        HStack {
                            Text("AMLL 歌词库")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.purple)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        
                        ForEach(amlldbResults) { candidate in
                            candidateRow(candidate)
                        }
                    }
                    
                    // LDDC Results Section Header
                    if !lddcResults.isEmpty {
                        HStack {
                            Text("其他平台")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        
                        ForEach(lddcResults) { candidate in
                            candidateRow(candidate)
                        }
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
                    ProgressView("搜索中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty {
                    emptyResultsPlaceholder
                } else {
                    List(selection: Binding(
                        get: { selectedCandidate?.id },
                        set: { newId in
                            if let candidate = searchResults.first(where: { $0.id == newId }) {
                                Task { await selectCandidate(candidate) }
                            }
                        }
                    )) {
                        // AMLLDB Section
                        if !amlldbResults.isEmpty {
                            Section("AMLL 歌词库") {
                                ForEach(amlldbResults) { candidate in
                                    candidateRow(candidate)
                                }
                            }
                        }
                        
                        // LDDC Section
                        if !lddcResults.isEmpty {
                            Section("其他平台") {
                                ForEach(lddcResults) { candidate in
                                    candidateRow(candidate)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    
    private var emptyResultsPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("未找到歌词")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var splitPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let candidate = selectedCandidate {
                Text("预览：\(candidate.title) - \(candidate.artist ?? "未知")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("预览")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Group {
                if isFetchingPreview {
                    ProgressView("加载预览...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = previewError {
                    errorBanner(message: error)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if selectedCandidate == nil {
                    emptyPreviewPlaceholder
                } else {
                    previewEditor
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    
    private var emptyPreviewPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("选择歌词查看预览")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("歌词预览")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                // Strip metadata toggle
                Toggle("去除元数据", isOn: $stripExtraInfo)
                    .toggleStyle(.switch)
                    .font(.caption)
                
                // Apply button
                Button {
                    Task { await applyLyrics() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                        Text("应用")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplying || editableOrig.isEmpty)
                .clipShape(Capsule())
            }
            
            previewEditor
        }
    }
    
    private var previewEditor: some View {
        VStack(spacing: 8) {
            // Original lyrics editor
            VStack(alignment: .leading, spacing: 4) {
                Text("原文")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                TextEditor(text: $editableOrig)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            
            // Translation editor (if available)
            if !editableTrans.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("翻译")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    TextEditor(text: $editableTrans)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
    
    private func candidateRow(_ candidate: LDDCCandidate) -> some View {
        Button {
            Task { await selectCandidate(candidate) }
        } label: {
            HStack(spacing: 8) {
                // Platform indicator
                Text(candidate.sourceEnum?.displayName ?? candidate.source)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(platformColor(candidate.sourceEnum ?? .LRCLIB).opacity(0.2))
                    .foregroundStyle(platformColor(candidate.sourceEnum ?? .LRCLIB))
                    .clipShape(Capsule())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        Text(candidate.artist ?? "未知")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        
                        if let album = candidate.album, !album.isEmpty {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(album)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                
                Spacer()
                
                // Score badge
                Text(String(format: "%.0f%%", candidate.score * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                selectedCandidate?.id == candidate.id
                ? Color.accentColor.opacity(0.15)
                : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
    
    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    // MARK: - Actions
    
    private func resetQueryForCurrentTrack() {
        searchTitle = track.title
        searchArtist = track.artist
        searchAlbum = track.album
        selectedCandidate = nil
        previewOrig = nil
        previewTrans = nil
        editableOrig = ""
        editableTrans = ""
        searchError = nil
        previewError = nil
        applyError = nil
        amlldbResults = []
        lddcResults = []
        searchResults = []
    }
    
    private func triggerAutoSearchIfNeeded(_ token: Int, force: Bool) {
        guard token > 0 else { return }
        if !force && token == lastAutoSearchToken {
            return
        }
        lastAutoSearchToken = token
        searchTitle = track.title
        searchArtist = track.artist
        searchAlbum = track.album
        includeTranslation = includeTranslationDefault
        Task { await performSearch() }
    }
    
    private func performSearch() async {
        guard !searchTitle.isEmpty else { return }
        
        Self.logger.info("[LyricsSearch] Starting search - title: '\(self.searchTitle)', artist: '\(self.searchArtist)', AMLLDB enabled: \(self.enableAMLLDB)")
        
        isSearching = true
        searchError = nil
        searchResults = []
        amlldbResults = []
        lddcResults = []
        selectedCandidate = nil
        previewOrig = nil
        previewTrans = nil
        editableOrig = ""
        editableTrans = ""
        
        // Check AMLLDB index status
        let indexAvailable = amlldbService.isIndexAvailable()
        let indexEntryCount = amlldbService.getIndexEntryCount()
        Self.logger.info("[LyricsSearch] AMLLDB index available: \(indexAvailable), entries: \(indexEntryCount)")
        
        // Start AMLLDB index update in background if needed (don't block search)
        if enableAMLLDB && !indexAvailable {
            Self.logger.info("[LyricsSearch] AMLLDB index not available, will update in background")
            amlldbIndexStatus = "正在初始化 AMLLDB 索引..."
            isUpdatingAMLLDBIndex = true
            
            Task {
                _ = await amlldbService.checkAndUpdateIfNeeded()
                await MainActor.run {
                    isUpdatingAMLLDBIndex = false
                    let newCount = amlldbService.getIndexEntryCount()
                    if newCount > 0 {
                        amlldbIndexStatus = "AMLLDB 索引已就绪 (\(newCount) 条)"
                        Self.logger.info("[LyricsSearch] AMLLDB index updated, entries: \(newCount)")
                    } else {
                        amlldbIndexStatus = "AMLLDB 索引初始化失败"
                        Self.logger.error("[LyricsSearch] AMLLDB index update failed")
                    }
                    // Clear status after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        amlldbIndexStatus = nil
                    }
                }
            }
        } else if enableAMLLDB && amlldbService.shouldUpdateIndex() {
            // Background update if needed
            Self.logger.info("[LyricsSearch] AMLLDB index needs update, starting background update")
            Task {
                _ = await amlldbService.checkAndUpdateIfNeeded()
            }
        }
        
        do {
            // Perform searches in parallel
            async let amlldbTask: [LDDCCandidate] = performAMLLDBSearch()
            async let lddcTask: [LDDCCandidate] = performLDDCSearch()
            
            let amlldbRes = await amlldbTask
            let lddcRes = await lddcTask
            
            // Store separate results
            amlldbResults = amlldbRes
            lddcResults = lddcRes
            
            // Combined results: AMLLDB first, then LDDC
            searchResults = amlldbResults + lddcResults
            
            Self.logger.info("[LyricsSearch] Search completed - AMLLDB: \(amlldbResults.count), LDDC: \(lddcResults.count), Total: \(searchResults.count)")
            
            if searchResults.isEmpty {
                if enableAMLLDB && !indexAvailable {
                    searchError = "正在初始化歌词索引，请稍后再试"
                } else {
                    searchError = "未找到可用歌词"
                }
            }
        } catch {
            Self.logger.error("[LyricsSearch] Search error: \(error.localizedDescription)")
            searchError = error.localizedDescription
        }
        
        isSearching = false
    }
    
    private func performLDDCSearch() async -> [LDDCCandidate] {
        guard !selectedLDDCSources.isEmpty else {
            Self.logger.info("[LyricsSearch] LDDC search skipped: no sources selected")
            return []
        }
        
        Self.logger.info("[LyricsSearch] Starting LDDC search with sources: \(selectedLDDCSources.map { $0.rawValue })")
        
        do {
            let response = try await client.search(
                title: searchTitle,
                artist: searchArtist.isEmpty ? nil : searchArtist,
                sources: Array(selectedLDDCSources),
                mode: selectedMode,
                translation: includeTranslation
            )
            
            Self.logger.info("[LyricsSearch] LDDC search completed: \(response.results.count) results")
            
            if let errors = response.errors, !errors.isEmpty {
                Self.logger.warning("[LyricsSearch] LDDC partial errors: \(errors.joined(separator: ", "))")
            }
            
            return response.results
        } catch {
            Self.logger.error("[LyricsSearch] LDDC search failed: \(error.localizedDescription)")
            return []
        }
    }
    
    private func performAMLLDBSearch() async -> [LDDCCandidate] {
        guard enableAMLLDB else {
            Self.logger.info("[LyricsSearch] AMLLDB search skipped: disabled")
            return []
        }
        
        let indexAvailable = amlldbService.isIndexAvailable()
        let indexCount = amlldbService.getIndexEntryCount()
        
        guard indexAvailable else {
            Self.logger.warning("[LyricsSearch] AMLLDB search skipped: index not available")
            return []
        }
        
        Self.logger.info("[LyricsSearch] Starting AMLLDB search - title: '\(searchTitle)', artist: '\(searchArtist)', album: '\(searchAlbum)'")
        
        let results = amlldbService.search(
            title: searchTitle,
            artist: searchArtist.isEmpty ? nil : searchArtist,
            album: searchAlbum.isEmpty ? nil : searchAlbum,
            duration: track.duration > 0 ? track.duration : nil,
            limit: 20
        )
        
        Self.logger.info("[LyricsSearch] AMLLDB search completed: \(results.count) results")
        
        return results.map { $0.toLDDCCandidate() }
    }
    
    private func selectCandidate(_ candidate: LDDCCandidate) async {
        Self.logger.info("[LyricsSearch] Selected candidate: \(candidate.title) from \(candidate.source)")
        
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
                Self.logger.info("[LyricsSearch] Downloaded AMLLDB TTML: \(ttml.count) bytes")
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
            Self.logger.error("[LyricsSearch] Failed to fetch preview: \(error.localizedDescription)")
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
                Self.logger.info("[LyricsSearch] Applying AMLLDB TTML directly")
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
            Self.logger.info("[LyricsSearch] Lyrics applied successfully")
            
        } catch {
            Self.logger.error("[LyricsSearch] Failed to apply lyrics: \(error.localizedDescription)")
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
