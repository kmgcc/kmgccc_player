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

    private struct SearchTrigger: Equatable {
        let trackID: UUID?
        let autoSearchToken: Int
        let requestID: Int
        let autoSearchOnAppear: Bool
    }

    private struct SearchContext: Equatable {
        let trackID: UUID?
        let autoSearchToken: Int
    }
    
    let track: Track?
    let initialTitle: String
    let initialArtist: String
    let initialAlbum: String
    let duration: Double
    let layoutStyle: LayoutStyle
    let includeTranslationDefault: Bool
    let autoSearchToken: Int
    let autoSearchOnAppear: Bool
    let onApplyLyrics: (String) -> Void
    
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(LibraryCacheServices.self) private var cacheServices

    // MARK: - Logger
    private static let logger = Logger(subsystem: "com.kmgccc.player", category: "LyricsSearch")
    
    @State private var searchTitle = ""
    @State private var searchArtist = ""
    @State private var searchAlbum = ""
    @State private var selectedMode: LDDCMode = .verbatim
    @State private var includeTranslation: Bool
    
    // LDDC platforms (separate from AMLLDB)
    @State private var selectedLDDCSources: Set<LDDCSource> = [.QM, .KG, .NE]
    // AMLLDB is always enabled
    @State private var enableAMLLDB = true
    
    @State private var searchRequestID = 0
    @State private var completedSearchContext: SearchContext?
    @State private var completedRequestID: Int?
    @State private var activeSearchID: UUID?

    @State private var isSearching = false
    @State private var searchResults: [LDDCCandidate] = []
    @State private var searchError: String?
    @State private var searchWarning: String?
    @State private var forceRetryUnreliableSourcesForNextSearch = false
    
    // Separate results for display
    @State private var amlldbResults: [LDDCCandidate] = []
    @State private var lddcResults: [LDDCCandidate] = []
    
    @State private var selectedCandidate: LDDCCandidate?
    @State private var isFetchingPreview = false
    @State private var editableOrig = ""
    @State private var editableTrans = ""
    @State private var previewError: String?
    
    @State private var isApplying = false
    @State private var applyError: String?
    @State private var applyNotice: String?
    @AppStorage("lddc.stripExtraInfo") private var stripExtraInfo = true

    // Selection requests are modeled as state so SwiftUI owns cancellation.
    @State private var pendingCandidate: LDDCCandidate?
    @State private var selectionRequestID = 0
    @State private var manualApplyRequestID: UUID?
    @State private var autoApplySuccess = false

    // Index update state
    @State private var isUpdatingAMLLDBIndex = false
    @State private var amlldbIndexStatus: String? = nil
    
    // Shared instance: this struct is re-initialized on every parent body
    // evaluation, so a per-instance LDDCClient would create a URLSession each time.
    private let client = LDDCClient.shared
    private let panelMaxWidth: CGFloat = 380
    private let visibleLDDCSources: [LDDCSource] = [.QM, .KG, .NE]

    // Phase 4.5: ordinary-text foregrounds tinted from the active palette.
    private var appFgPrimary: Color { themeStore.appForegroundPalette.primaryColor }
    private var appFgSecondary: Color { themeStore.appForegroundPalette.secondaryColor }
    private var appFgTertiary: Color { themeStore.appForegroundPalette.tertiaryColor }

    private var searchTrigger: SearchTrigger {
        SearchTrigger(
            trackID: track?.id,
            autoSearchToken: autoSearchToken,
            requestID: searchRequestID,
            autoSearchOnAppear: autoSearchOnAppear
        )
    }
    
    init(
        track: Track,
        layoutStyle: LayoutStyle = .stacked,
        includeTranslationDefault: Bool = true,
        autoSearchToken: Int = 0,
        autoSearchOnAppear: Bool = true,
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
        self.autoSearchOnAppear = autoSearchOnAppear
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
        autoSearchOnAppear: Bool = false,
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
        self.autoSearchOnAppear = autoSearchOnAppear
        self.onApplyLyrics = onApplyLyrics
        _includeTranslation = State(initialValue: includeTranslationDefault)
    }
    
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
            } else if let warning = searchWarning {
                noticeBanner(message: warning)
            } else if let notice = applyNotice {
                noticeBanner(message: notice)
            }
        }
        .task(id: searchTrigger) {
            let context = SearchContext(
                trackID: track?.id,
                autoSearchToken: autoSearchToken
            )
            let contextNeedsSearch = completedSearchContext != context

            if contextNeedsSearch {
                resetQueryForCurrentTrack()
                forceRetryUnreliableSourcesForNextSearch = false
                completedSearchContext = context
                if !autoSearchOnAppear {
                    completedRequestID = searchRequestID
                }
            }

            let requestNeedsSearch = completedRequestID != searchRequestID
            let shouldSearch = requestNeedsSearch || (contextNeedsSearch && autoSearchOnAppear)
            guard shouldSearch else { return }

            let token = FirstUseHitchDiagnostics.begin(
                "LyricsSearchSection.autoSearch",
                detail: "request=\(searchRequestID), hasTrack=\(track != nil)"
            )
            let forceRetryUnreliableSources = forceRetryUnreliableSourcesForNextSearch
            forceRetryUnreliableSourcesForNextSearch = false
            let completed = await performSearch(
                forceRetryUnreliableSources: forceRetryUnreliableSources
            )
            FirstUseHitchDiagnostics.end(token)

            guard completed else { return }
            completedSearchContext = context
            completedRequestID = searchRequestID
        }
        .task(id: selectionRequestID) {
            guard let candidate = pendingCandidate else { return }
            await processCandidateSelection(candidate)
        }
        .task(id: manualApplyRequestID) {
            guard manualApplyRequestID != nil else { return }
            await applyLyrics()
        }
        .onDisappear {
            pendingCandidate = nil
            manualApplyRequestID = nil
            forceRetryUnreliableSourcesForNextSearch = false
            isFetchingPreview = false
            isApplying = false
            // Search results and previews are transient. Release their TTML
            // strings when the editor leaves instead of keeping the last search
            // alive in SwiftUI state across repeated sheet presentations.
            searchResults.removeAll(keepingCapacity: false)
            amlldbResults.removeAll(keepingCapacity: false)
            lddcResults.removeAll(keepingCapacity: false)
            selectedCandidate = nil
            editableOrig = ""
            editableTrans = ""
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
                        .foregroundStyle(appFgSecondary)
                    TextField(
                        "歌曲名", text: $searchTitle
                    )
                    .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("艺人")
                        .font(.caption)
                        .foregroundStyle(appFgSecondary)
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
                        .foregroundStyle(appFgSecondary)

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
                    .padding(3)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }

                HStack(spacing: 4) {
                    Text("翻译")
                        .font(.subheadline)
                        .foregroundStyle(appFgSecondary)

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
                    .padding(3)
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
                    .foregroundStyle(appFgSecondary)

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
                    forceRetryUnreliableSourcesForNextSearch = true
                    searchRequestID &+= 1
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                        Text("搜索")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    searchTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSearching
                )
                .clipShape(Capsule())
            }
        }
        .disabled(isSearching)
    }
    
    // MARK: - Results Section
    
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Results Summary - simple count only
            HStack {
                Text("搜索结果：\(searchResults.count)")
                    .font(.subheadline)
                    .foregroundStyle(appFgSecondary)
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
                .foregroundStyle(appFgSecondary)

            Group {
                if !searchResults.isEmpty {
                    List {
                        // Unified results list; keep already completed sources
                        // visible while slower providers are still running.
                        ForEach(searchResults) { candidate in
                            candidateRow(candidate)
                        }
                    }
                    .listStyle(.plain)
                } else if isSearching {
                    ProgressView("搜索中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyResultsPlaceholder
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
                .foregroundStyle(appFgTertiary)
            Text("未找到歌词")
                .foregroundStyle(appFgSecondary)
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
                        .foregroundStyle(appFgSecondary)
                        .lineLimit(1)
                } else {
                    Text("预览")
                        .font(.subheadline)
                        .foregroundStyle(appFgSecondary)
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
                .foregroundStyle(appFgTertiary)
            Text("选择歌词查看预览")
                .foregroundStyle(appFgSecondary)
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
                    .foregroundStyle(appFgSecondary)

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
                manualApplyRequestID = UUID()
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
                    .foregroundStyle(appFgSecondary)

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
                        .foregroundStyle(appFgSecondary)
                    
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
            pendingCandidate = candidate
            selectionRequestID &+= 1
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
                        .foregroundStyle(appFgPrimary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(candidate.artist ?? "未知")
                            .font(.caption)
                            .foregroundStyle(appFgSecondary)
                            .lineLimit(1)

                        if let album = candidate.album, !album.isEmpty {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(appFgSecondary)
                            Text(album)
                                .font(.caption)
                                .foregroundStyle(appFgSecondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Score badge - properly normalized 0-100%
                Text(String(format: "%.0f%%", displayScore))
                    .font(.caption2)
                    .foregroundStyle(appFgTertiary)
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

    private func noticeBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
            Spacer()
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    // MARK: - Actions

    private func resetSearchStateForNewRequest() {
        selectionRequestID &+= 1
        pendingCandidate = nil
        manualApplyRequestID = nil
        selectedCandidate = nil
        autoApplySuccess = false
        editableOrig = ""
        editableTrans = ""
        searchError = nil
        searchWarning = nil
        previewError = nil
        applyError = nil
        applyNotice = nil
        amlldbResults = []
        lddcResults = []
        searchResults = []
        isFetchingPreview = false
        isApplying = false
        isUpdatingAMLLDBIndex = false
        amlldbIndexStatus = nil
    }

    private func resetQueryForCurrentTrack() {
        searchTitle = initialTitle
        searchArtist = initialArtist
        searchAlbum = initialAlbum
        includeTranslation = includeTranslationDefault
        resetSearchStateForNewRequest()
    }

    private func performSearch(forceRetryUnreliableSources: Bool = false) async -> Bool {
        guard !searchTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSearching = false
            return true
        }

        let requestID = UUID()
        activeSearchID = requestID
        resetSearchStateForNewRequest()
        isSearching = true
        var lddcErrors: [String] = []
        var amlldbFailure: String?

        Self.logger.debug(
            "[LyricsSearch] Starting search - title: '\(searchTitle)', artist: '\(searchArtist)', AMLLDB enabled: \(enableAMLLDB)"
        )

        let updates = cacheServices.lyricsSearchCoordinator.search(
            title: searchTitle,
            artist: searchArtist.isEmpty ? nil : searchArtist,
            album: searchAlbum.isEmpty ? nil : searchAlbum,
            duration: duration > 0 ? duration : nil,
            lddcSources: selectedLDDCSources,
            enableAMLLDB: enableAMLLDB,
            mode: selectedMode,
            translation: includeTranslation,
            sourcePolicy: forceRetryUnreliableSources ? .forceAll : .adaptive
        )

        for await update in updates {
            guard !Task.isCancelled, activeSearchID == requestID else {
                return false
            }

            switch update {
            case .amlldbStatus(let message, let isUpdating):
                isUpdatingAMLLDBIndex = isUpdating
                amlldbIndexStatus = message

            case .amlldbResults(let results):
                amlldbResults = results

            case .amlldbFailure(let message):
                isUpdatingAMLLDBIndex = false
                amlldbIndexStatus = message
                amlldbFailure = message
                Self.logger.error("[LyricsSearch] AMLLDB search failed: \(message)")

            case .lddc(let outcome):
                lddcResults.append(contentsOf: outcome.results)
                lddcErrors.append(contentsOf: outcome.errors)

                Self.logger.debug(
                    "[LyricsSearch] \(outcome.source.rawValue) returned \(outcome.results.count) results"
                )
                if !outcome.errors.isEmpty {
                    Self.logger.warning(
                        "[LyricsSearch] \(outcome.source.rawValue) failed: \(outcome.errors.joined(separator: ", "))"
                    )
                }
            }

            searchResults = mergeAndSortResults(amlldb: amlldbResults, lddc: lddcResults)
        }

        guard !Task.isCancelled, activeSearchID == requestID else {
            return false
        }

        isUpdatingAMLLDBIndex = false
        isSearching = false

        if searchResults.isEmpty {
            if amlldbFailure != nil || !lddcErrors.isEmpty {
                searchError = "歌词来源请求失败，请稍后重试"
            } else {
                searchError = "未找到可用歌词"
            }
        } else if amlldbFailure != nil || !lddcErrors.isEmpty {
            searchWarning = "部分歌词来源暂时不可用，已显示其他来源结果"
        }

        Self.logger.debug(
            "[LyricsSearch] merged result count: \(searchResults.count) (AMLLDB: \(amlldbResults.count), LDDC: \(lddcResults.count))"
        )
        return true
    }

    // MARK: - Result Merging & Sorting

    /// Merge AMLLDB and LDDC results with proper ranking.
    /// Delegates to the shared LyricsSearchHelper for consistency with import flow.
    private func mergeAndSortResults(amlldb: [LDDCCandidate], lddc: [LDDCCandidate]) -> [LDDCCandidate] {
        LyricsSearchHelper.mergeAndSortResults(amlldb: amlldb, lddc: lddc)
    }

    private func processCandidateSelection(_ candidate: LDDCCandidate) async {
        guard !Task.isCancelled, pendingCandidate?.id == candidate.id else {
            Self.logger.info("[LyricsSearch] Selection task cancelled for: \(candidate.title)")
            return
        }

        selectedCandidate = candidate
        isFetchingPreview = true
        previewError = nil
        applyError = nil
        applyNotice = nil

        let artistName = candidate.artist ?? "未知"
        Self.logger.info("[LyricsSearch] Candidate clicked: \(candidate.title) / \(artistName) / \(candidate.source)")
        Self.logger.info("[LyricsSearch] Preview load start for: \(candidate.title)")

        // Load preview content
        var loadedOrig: String?
        var loadedTrans: String?

        do {
            if candidate.source == "AMLLDB" {
                // AMLLDB: Download via rawLyricFile (stored in songId)
                let rawLyricFile = candidate.songId
                let ttml = try await cacheServices.amllDBService.downloadLyricsByRawFile(rawLyricFile)
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
                if selectedCandidate?.id == candidate.id {
                    isFetchingPreview = false
                }
                return
            }

            // Update preview state
            editableOrig = loadedOrig ?? ""
            editableTrans = loadedTrans ?? ""
            isFetchingPreview = false

        } catch {
            if Task.isCancelled || Self.isCancellationError(error) {
                if selectedCandidate?.id == candidate.id {
                    isFetchingPreview = false
                }
                return
            }

            guard selectedCandidate?.id == candidate.id else { return }
            isFetchingPreview = false
            Self.logger.error("[LyricsSearch] Preview load failure: \(error.localizedDescription)")
            previewError = error.localizedDescription
            return
        }

        // Auto-apply after successful preview load
        guard let origLyrics = loadedOrig, !origLyrics.isEmpty else {
            Self.logger.error("[LyricsSearch] Preview content empty, skipping auto-apply")
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
        defer {
            isApplying = false
        }
        applyError = nil
        applyNotice = nil

        do {
            let ttml: String

            // Check if this is an AMLLDB result (already TTML format)
            if candidate.source == "AMLLDB" {
                guard let normalized = LyricsFormatSupport.normalizedTTMLText(origLyrics) else {
                    throw TTMLConversionError.conversionFailed("AMLLDB TTML 结构无效")
                }
                ttml = normalized
                Self.logger.info("[LyricsApply] AMLLDB TTML applied directly")
            } else if includeTranslation, let trans = transLyrics, !trans.isEmpty {
                let converted = try await TTMLConverter.shared.convertToTTMLWithTranslation(
                    origLyrics: origLyrics,
                    transLyrics: trans,
                    stripMetadata: stripExtraInfo
                )
                guard let normalized = LyricsFormatSupport.normalizedTTMLText(converted) else {
                    throw TTMLConversionError.conversionFailed("LDDC 转换结果 TTML 结构无效")
                }
                ttml = normalized
                Self.logger.info("[LyricsApply] LDDC converted to TTML with translation")
            } else {
                let converted = try await TTMLConverter.shared.convertToTTML(
                    rawLyrics: origLyrics,
                    stripMetadata: stripExtraInfo
                )
                guard let normalized = LyricsFormatSupport.normalizedTTMLText(converted) else {
                    throw TTMLConversionError.conversionFailed("LDDC 转换结果 TTML 结构无效")
                }
                ttml = normalized
                Self.logger.info("[LyricsApply] LDDC converted to TTML")
            }

            // Verify again before final apply
            guard selectedCandidate?.id == candidate.id else {
                Self.logger.info("[LyricsApply] Candidate changed during conversion, aborting")
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

        } catch LRCConversionError.instrumentalPlaceholderLyrics {
            Self.logger.info("[LyricsApply] LDDC returned instrumental placeholder lyrics; skipping apply")
            applyNotice = LRCConversionError.instrumentalPlaceholderLyrics.localizedDescription
        } catch {
            if Task.isCancelled || Self.isCancellationError(error) {
                return
            }
            Self.logger.error("[LyricsApply] Apply failure: \(error.localizedDescription)")
            applyError = error.localizedDescription
        }
    }
    
    // MARK: - Manual Apply (fallback)

    private func applyLyrics() async {
        guard !isFetchingPreview, !isApplying else {
            Self.logger.debug("[LyricsApply] Manual apply ignored while another lyrics operation is active")
            return
        }

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

    private nonisolated static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }
    
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
