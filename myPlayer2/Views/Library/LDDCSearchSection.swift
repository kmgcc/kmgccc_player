//
//  LDDCSearchSection.swift
//  myPlayer2
//
//  kmgccc_player - LDDC Lyrics Search Section View
//  Embedded in TrackEditSheet for searching and applying lyrics.
//

import SwiftUI
import SwiftData
import os.log

/// LDDC lyrics search section with Liquid Glass styling.
struct LDDCSearchSection: View {
    
    enum LayoutStyle {
        case stacked
        case split
    }
    
    let track: Track?
    let initialTitle: String
    let initialArtist: String
    let initialAlbum: String
    let duration: Double
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

    // Track current selection task to handle quick clicks
    @State private var currentSelectionTask: Task<Void, Never>?
    @State private var applyingCandidateId: String?
    @State private var autoApplySuccess = false

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
        self.initialTitle = track.title
        self.initialArtist = track.artist
        self.initialAlbum = track.album
        self.duration = track.duration
        self.layoutStyle = layoutStyle
        self.includeTranslationDefault = includeTranslationDefault
        self.autoSearchToken = autoSearchToken
        self.onApplyLyrics = onApplyLyrics
        _includeTranslation = State(initialValue: includeTranslationDefault)
    }

    init(
        title: String,
        artist: String,
        album: String,
        duration: Double,
        layoutStyle: LayoutStyle = .stacked,
        includeTranslationDefault: Bool = true,
        autoSearchToken: Int = 0,
        onApplyLyrics: @escaping (String) -> Void
    ) {
        self.track = nil
        self.initialTitle = title
        self.initialArtist = artist
        self.initialAlbum = album
        self.duration = duration
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
            let token = FirstUseHitchDiagnostics.begin(
                "LyricsSearchSection.onAppear",
                detail: "autoSearch=\(autoSearchToken), hasTrack=\(track != nil)"
            )
            // Setup AMLLDB model context
            amlldbService.setupModelContext(modelContext)
            Self.logger.info("[LyricsSearch] View appeared, AMLLDB model context set")
            
            resetQueryForCurrentTrack()
            triggerAutoSearchIfNeeded(autoSearchToken, force: true)
            FirstUseHitchDiagnostics.end(token)
        }
        .onChange(of: track?.id) { _, _ in
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
                    Text("艺人")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "艺人", text: $searchArtist
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }
            
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("模式")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    SlidingSelector(
                        segments: LDDCMode.allCases,
                        selection: $selectedMode,
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
                            Text(mode.displayName)
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

                HStack(spacing: 4) {
                    Text("翻译")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    SlidingSelector(
                        segments: [true, false],
                        selection: $includeTranslation,
                        animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                        hSpacing: 0,
                        background: {
                            Color.clear
                        },
                        knob: {
                            Capsule()
                                .fill(themeStore.accentColor.opacity(0.18))
                        },
                        content: { enabled, isSelected in
                            Text(enabled ? "开" : "关")
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

                Spacer()
            }
            
            // Platform Selection
            HStack(spacing: 12) {
                Text("平台")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // AMLLDB Toggle (separate from LDDC)
                Toggle(
                    "AMLL DB",
                    isOn: $enableAMLLDB
                )
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(enableAMLLDB ? .blue : .secondary)
                .clipShape(Capsule())

                // LDDC Platforms
                HStack(spacing: 8) {
                    ForEach(visibleLDDCSources) { source in
                        let isSelected = selectedLDDCSources.contains(source)
                        Toggle(
                            source.displayName,
                            isOn: Binding(
                                get: { isSelected },
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
                        .tint(isSelected ? platformColor(source) : Color.secondary)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
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
            // Results Summary - simple count only
            HStack {
                Text("搜索结果：\(searchResults.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    // Unified results list (no separate sections)
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
                    ProgressView("搜索中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty {
                    emptyResultsPlaceholder
                } else {
                    List {
                        // Unified results list (no separate sections)
                        ForEach(searchResults) { candidate in
                            candidateRow(candidate)
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
            HStack {
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

                Spacer()

                // Auto-apply success indicator
                if autoApplySuccess {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("已应用")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            previewActionBar

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

                // Auto-apply success indicator
                if autoApplySuccess {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("已应用")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            previewActionBar

            previewEditor
        }
    }

    private var previewActionBar: some View {
        HStack(spacing: 12) {
            Toggle("去除多余信息", isOn: $stripExtraInfo)
                .toggleStyle(.switch)
                .font(.caption)

            Spacer()

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
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.trailing, 18)
            }
            
            // Translation editor (if available)
            if !editableTrans.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("翻译")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    TextEditor(text: $editableTrans)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 80)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(.trailing, 18)
                }
            }
        }
    }
    
    private func candidateRow(_ candidate: LDDCCandidate) -> some View {
        Button {
            Task { await selectCandidate(candidate) }
        } label: {
            let displayScore = candidate.normalizedScore()

            HStack(spacing: 8) {
                // Fixed-width badge area for consistent text alignment
                Text(candidate.sourceEnum?.displayName ?? candidate.source)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(platformColor(candidate.sourceEnum ?? .LRCLIB).opacity(0.2))
                    .foregroundStyle(platformColor(candidate.sourceEnum ?? .LRCLIB))
                    .clipShape(Capsule())
                    .frame(width: 64, alignment: .leading)

                // Text content - always starts at same horizontal position
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

                // Score badge - properly normalized 0-100%
                Text(String(format: "%.0f%%", displayScore))
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
            .contentShape(Rectangle()) // Make whole row clickable
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
        // Cancel any pending selection task
        currentSelectionTask?.cancel()
        currentSelectionTask = nil

        searchTitle = initialTitle
        searchArtist = initialArtist
        searchAlbum = initialAlbum
        selectedCandidate = nil
        applyingCandidateId = nil
        autoApplySuccess = false
        previewOrig = nil
        previewTrans = nil
        editableOrig = ""
        editableTrans = ""
        searchError = nil
        previewError = nil
        applyError = nil
        stripExtraInfo = false
        amlldbResults = []
        lddcResults = []
        searchResults = []
        isUpdatingAMLLDBIndex = false
        amlldbIndexStatus = nil
    }
    
    private func triggerAutoSearchIfNeeded(_ token: Int, force: Bool) {
        guard token > 0 else { return }
        if !force && token == lastAutoSearchToken {
            return
        }
        lastAutoSearchToken = token
        searchTitle = initialTitle
        searchArtist = initialArtist
        searchAlbum = initialAlbum
        includeTranslation = includeTranslationDefault
        Task { await performSearch() }
    }
    
    private func performSearch() async {
        guard !searchTitle.isEmpty else { return }

        // Cancel any pending selection task
        currentSelectionTask?.cancel()
        currentSelectionTask = nil

        Self.logger.debug("[LyricsSearch] Starting search - title: '\(self.searchTitle)', artist: '\(self.searchArtist)', AMLLDB enabled: \(self.enableAMLLDB)")
        
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

        let initialAMLLDBStatus = enableAMLLDB ? amlldbService.getIndexStatus() : nil
        if let initialAMLLDBStatus {
            Self.logger.debug(
                "[LyricsSearch] AMLLDB getIndexStatus -> available=\(initialAMLLDBStatus.available), entryCount=\(initialAMLLDBStatus.entryCount), lastUpdatedAt=\(String(describing: initialAMLLDBStatus.lastUpdatedAt)), reason=\(initialAMLLDBStatus.reason)"
            )
        } else {
            amlldbIndexStatus = nil
        }

        async let lddcTask: [LDDCCandidate] = performLDDCSearch()
        let searchableAMLLDBStatus = await ensureAMLLDBReadyForCurrentSearch(initialAMLLDBStatus)
        let amlldbRes = await performAMLLDBSearch(using: searchableAMLLDBStatus)
        let lddcRes = await lddcTask

        amlldbResults = amlldbRes
        lddcResults = lddcRes

        // Log raw scores for debugging (only in debug builds)
        #if DEBUG
        for candidate in amlldbResults {
            let normScore = candidate.normalizedScore()
            Self.logger.debug("[LyricsSearch] AMLLDB result: '\(candidate.title)' rawScore=\(candidate.score) normalized=\(normScore)")
        }
        for candidate in lddcResults {
            let normScore = candidate.normalizedScore()
            Self.logger.debug("[LyricsSearch] LDDC result: '\(candidate.title)' source=\(candidate.source) rawScore=\(candidate.score) normalized=\(normScore)")
        }
        #endif

        // Merge with proper ranking:
        // 1. High-confidence AMLLDB (>=80%) first, sorted by score desc
        // 2. All other results sorted by normalized score desc
        searchResults = mergeAndSortResults(amlldb: amlldbResults, lddc: lddcResults)

        Self.logger.debug("[LyricsSearch] merged result count: \(searchResults.count) (AMLLDB: \(amlldbResults.count), LDDC: \(lddcResults.count))")

        if searchResults.isEmpty {
            if enableAMLLDB,
               let searchableAMLLDBStatus,
               !searchableAMLLDBStatus.available,
               let initError = amlldbService.lastError
            {
                searchError = initError
            } else {
                searchError = "未找到可用歌词"
            }
        }
        
        isSearching = false
    }

    private func ensureAMLLDBReadyForCurrentSearch(_ status: AMLLDBIndexStatus?) async -> AMLLDBIndexStatus? {
        guard enableAMLLDB else {
            Self.logger.debug("[LyricsSearch] AMLLDB search skipped: disabled")
            return nil
        }

        // Check current status
        let currentStatus = amlldbService.getIndexStatus()

        if currentStatus.available {
            Self.logger.debug("[LyricsSearch] AMLLDB index ready: \(currentStatus.reason)")
            amlldbIndexStatus = nil
            return currentStatus
        }

        // Need to initialize - show status
        amlldbIndexStatus = "正在初始化 AMLLDB 索引..."
        isUpdatingAMLLDBIndex = true

        // Ensure index is ready
        let ready = await amlldbService.ensureIndexReady()
        isUpdatingAMLLDBIndex = false

        let newStatus = amlldbService.getIndexStatus()

        if ready && newStatus.available {
            amlldbIndexStatus = "AMLLDB 索引已就绪 (\(newStatus.entryCount) 条)"
            Self.logger.debug("[LyricsSearch] AMLLDB index initialized: \(newStatus.entryCount) entries")
            clearAMLLDBStatusBannerAfterDelay()
        } else {
            let failureMessage = amlldbService.lastError ?? "AMLLDB 索引初始化失败"
            amlldbIndexStatus = failureMessage
            Self.logger.error("[LyricsSearch] AMLLDB initialization failed: \(failureMessage)")
        }

        return newStatus
    }

    private func startAMLLDBSilentRefresh() {
        Task {
            do {
                _ = try await amlldbService.checkAndUpdateIfNeeded()
            } catch {
                Self.logger.error("[LyricsSearch] AMLLDB silent refresh failed: \(error.localizedDescription)")
            }
        }
    }

    private func clearAMLLDBStatusBannerAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if !isUpdatingAMLLDBIndex {
                amlldbIndexStatus = nil
            }
        }
    }
    
    private func performLDDCSearch() async -> [LDDCCandidate] {
        guard !selectedLDDCSources.isEmpty else {
            Self.logger.debug("[LyricsSearch] LDDC search skipped: no sources selected")
            return []
        }
        
        Self.logger.debug("[LyricsSearch] Starting LDDC search with sources: \(selectedLDDCSources.map { $0.rawValue })")
        
        do {
            let response = try await client.search(
                title: searchTitle,
                artist: searchArtist.isEmpty ? nil : searchArtist,
                sources: Array(selectedLDDCSources),
                mode: selectedMode,
                translation: includeTranslation
            )
            
            Self.logger.debug("[LyricsSearch] LDDC search completed: \(response.results.count) results")
            
            if let errors = response.errors, !errors.isEmpty {
                Self.logger.warning("[LyricsSearch] LDDC partial errors: \(errors.joined(separator: ", "))")
            }
            
            return response.results
        } catch {
            Self.logger.error("[LyricsSearch] LDDC search failed: \(error.localizedDescription)")
            return []
        }
    }
    
    private func performAMLLDBSearch(using status: AMLLDBIndexStatus?) async -> [LDDCCandidate] {
        guard enableAMLLDB else {
            Self.logger.debug("[LyricsSearch] AMLLDB search skipped: disabled")
            return []
        }
        
        let currentStatus = status ?? amlldbService.getIndexStatus()
        
        guard currentStatus.available else {
            Self.logger.warning("[LyricsSearch] AMLLDB search skipped: index not available (\(currentStatus.reason))")
            return []
        }
        
        Self.logger.debug(
            "[LyricsSearch] Starting AMLLDB search - title: '\(searchTitle)', artist: '\(searchArtist)', album: '\(searchAlbum)', entryCount: \(currentStatus.entryCount)"
        )
        
        let results = amlldbService.search(
            title: searchTitle,
            artist: searchArtist.isEmpty ? nil : searchArtist,
            album: searchAlbum.isEmpty ? nil : searchAlbum,
            duration: duration > 0 ? duration : nil,
            limit: 20
        )
        
        Self.logger.debug("[LyricsSearch] AMLLDB final result count: \(results.count)")

        return results.map { $0.toLDDCCandidate() }
    }

    // MARK: - Result Merging & Sorting

    /// Merge AMLLDB and LDDC results with proper ranking.
    /// Delegates to the shared LyricsSearchHelper for consistency with import flow.
    private func mergeAndSortResults(amlldb: [LDDCCandidate], lddc: [LDDCCandidate]) -> [LDDCCandidate] {
        LyricsSearchHelper.mergeAndSortResults(amlldb: amlldb, lddc: lddc)
    }

    private func selectCandidate(_ candidate: LDDCCandidate) async {
        Self.logger.info("[LyricsSearch] Candidate clicked: \(candidate.source) / \(candidate.title) / \(candidate.songId)")

        // Cancel any previous selection task
        currentSelectionTask?.cancel()

        // Create new task for this selection
        let task = Task {
            await processCandidateSelection(candidate)
        }
        currentSelectionTask = task

        await task.value
    }

    private func processCandidateSelection(_ candidate: LDDCCandidate) async {
        // Check if cancelled
        guard !Task.isCancelled else {
            Self.logger.info("[LyricsSearch] Selection task cancelled for: \(candidate.title)")
            return
        }

        selectedCandidate = candidate
        applyingCandidateId = candidate.id
        isFetchingPreview = true
        previewError = nil
        previewOrig = nil
        previewTrans = nil
        applyError = nil

        Self.logger.info("[LyricsSearch] Preview load start for: \(candidate.title)")

        // Load preview content
        var loadedOrig: String?
        var loadedTrans: String?

        do {
            if candidate.source == "AMLLDB" {
                // AMLLDB: Download via rawLyricFile (stored in songId)
                let rawLyricFile = candidate.songId
                let ttml = try await amlldbService.downloadLyricsByRawFile(rawLyricFile)
                loadedOrig = ttml
                loadedTrans = nil
                Self.logger.info("[LyricsSearch] Preview load success - AMLLDB TTML: \(rawLyricFile), \(ttml.count) bytes")
            } else if includeTranslation {
                let (orig, trans) = try await client.fetchByIdSeparate(
                    candidate: candidate,
                    mode: selectedMode
                )
                loadedOrig = orig
                loadedTrans = trans
                Self.logger.info("[LyricsSearch] Preview load success - LDDC with translation: \(orig.count) bytes")
            } else {
                let lyrics = try await client.fetchById(
                    candidate: candidate,
                    mode: selectedMode,
                    translation: false
                )
                loadedOrig = lyrics
                loadedTrans = nil
                Self.logger.info("[LyricsSearch] Preview load success - LDDC: \(lyrics.count) bytes")
            }

            // Check if cancelled after download
            guard !Task.isCancelled else {
                Self.logger.info("[LyricsSearch] Selection task cancelled after preview load")
                return
            }

            // Update preview state
            previewOrig = loadedOrig
            previewTrans = loadedTrans
            editableOrig = loadedOrig ?? ""
            editableTrans = loadedTrans ?? ""
            isFetchingPreview = false

        } catch {
            isFetchingPreview = false
            Self.logger.error("[LyricsSearch] Preview load failure: \(error.localizedDescription)")
            previewError = error.localizedDescription
            applyingCandidateId = nil
            return
        }

        // Auto-apply after successful preview load
        guard let origLyrics = loadedOrig, !origLyrics.isEmpty else {
            Self.logger.error("[LyricsSearch] Preview content empty, skipping auto-apply")
            applyingCandidateId = nil
            return
        }

        // Check if this is still the current selection (not cancelled by another click)
        guard selectedCandidate?.id == candidate.id else {
            Self.logger.info("[LyricsSearch] Selection changed, skipping auto-apply")
            return
        }

        Self.logger.info("[LyricsSearch] Auto-apply start for: \(candidate.title)")

        // Perform auto-apply
        await performApplyLyrics(candidate: candidate, origLyrics: origLyrics, transLyrics: loadedTrans)
    }

    private func performApplyLyrics(candidate: LDDCCandidate, origLyrics: String, transLyrics: String?) async {
        // Verify this is still the current candidate
        guard selectedCandidate?.id == candidate.id else {
            Self.logger.info("[LyricsApply] Candidate changed, aborting apply")
            return
        }

        isApplying = true
        applyError = nil

        do {
            let ttml: String

            // Check if this is an AMLLDB result (already TTML format)
            if candidate.source == "AMLLDB" {
                ttml = origLyrics
                Self.logger.info("[LyricsApply] AMLLDB TTML applied directly")
            } else if includeTranslation, let trans = transLyrics, !trans.isEmpty {
                ttml = try await TTMLConverter.shared.convertToTTMLWithTranslation(
                    origLyrics: origLyrics,
                    transLyrics: trans,
                    stripMetadata: stripExtraInfo
                )
                Self.logger.info("[LyricsApply] LDDC converted to TTML with translation")
            } else {
                ttml = try await TTMLConverter.shared.convertToTTML(
                    rawLyrics: origLyrics,
                    stripMetadata: stripExtraInfo
                )
                Self.logger.info("[LyricsApply] LDDC converted to TTML")
            }

            // Verify again before final apply
            guard selectedCandidate?.id == candidate.id else {
                Self.logger.info("[LyricsApply] Candidate changed during conversion, aborting")
                isApplying = false
                return
            }

            // Apply to track
            onApplyLyrics(ttml)

            autoApplySuccess = true
            Self.logger.info("[LyricsApply] Apply success - lyrics written to track")

            // Clear success indicator after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if autoApplySuccess {
                    autoApplySuccess = false
                }
            }

        } catch {
            Self.logger.error("[LyricsApply] Apply failure: \(error.localizedDescription)")
            applyError = error.localizedDescription
        }

        isApplying = false
        applyingCandidateId = nil
    }
    
    // MARK: - Manual Apply (fallback)

    private func applyLyrics() async {
        guard let candidate = selectedCandidate else {
            Self.logger.warning("[LyricsApply] Manual apply called but no candidate selected")
            return
        }

        let origLyrics = editableOrig.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !origLyrics.isEmpty else {
            Self.logger.warning("[LyricsApply] Manual apply called but no lyrics content")
            return
        }

        Self.logger.info("[LyricsApply] Manual apply triggered for: \(candidate.title)")
        await performApplyLyrics(candidate: candidate, origLyrics: origLyrics, transLyrics: editableTrans.isEmpty ? nil : editableTrans)
    }
    
    // MARK: - Helpers
    
    private func platformColor(_ source: LDDCSource) -> Color {
        switch source {
        case .QM: return .green
        case .KG: return .orange
        case .NE: return .red
        case .LRCLIB: return .blue
        case .AMLLDB: return .blue
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
