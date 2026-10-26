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
    
    @Environment(\.colorScheme) private var colorScheme
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
    @State private var selectedLDDCSources: Set<LDDCSource> = [.QM, .KG, .NE, .LRCLIB]
    // AMLLDB selection is independent from the LDDC platforms
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
    @AppStorage("lddc.fixTimingProblems") private var fixTimingProblems = true

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
    private let visibleLDDCSources: [LDDCSource] = [.QM, .KG, .NE, .LRCLIB]

    // Phase 4.5: ordinary-text foregrounds tinted from the active palette.
    private var appFgPrimary: Color { themeStore.appForegroundPalette.primaryColor }
    private var appFgSecondary: Color { themeStore.appForegroundPalette.secondaryColor }
    private var appFgTertiary: Color { themeStore.appForegroundPalette.tertiaryColor }

    private var hasSelectedSource: Bool { enableAMLLDB || !selectedLDDCSources.isEmpty }

    private var visibleSearchResults: [LDDCCandidate] {
        searchResults.filter { candidate in
            guard let source = candidate.sourceEnum else { return false }
            return source == .AMLLDB ? enableAMLLDB : selectedLDDCSources.contains(source)
        }
    }

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
        VStack(alignment: .leading, spacing: SettingsStyleTokens.sectionSpacing) {
            SettingsSection("歌词搜索", headerTrailing: {
                if isSearching || isFetchingPreview || isApplying || isUpdatingAMLLDBIndex {
                    ProgressView()
                        .controlSize(.small)
                }
            }) {
                searchFormSection
            }

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
                .foregroundStyle(themeStore.accentColor)
            Text(status)
                .font(.system(size: SettingsStyleTokens.descriptionFontSize))
            if isUpdatingAMLLDBIndex {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .appPopupContentBackground(tint: themeStore.accentColor)
    }

    // MARK: - Search Form

    private var searchFormSection: some View {
        VStack(alignment: .leading, spacing: TrackInfoEditorLayout.rowSpacing) {
            TrackInfoFieldRow("歌曲名", prompt: "歌曲名", text: $searchTitle)
            TrackInfoFieldRow("艺人", prompt: "艺人", text: $searchArtist)

            HStack(spacing: 12) {
                Text("平台")
                    .settingsRowLabelStyle()
                    .frame(width: TrackInfoEditorLayout.fieldLabelWidth, alignment: .leading)

                HStack(spacing: 6) {
                    sourceChip(.AMLLDB, isSelected: enableAMLLDB) {
                        enableAMLLDB.toggle()
                    }
                    ForEach(visibleLDDCSources) { source in
                        sourceChip(source, isSelected: selectedLDDCSources.contains(source)) {
                            if selectedLDDCSources.contains(source) {
                                selectedLDDCSources.remove(source)
                            } else {
                                selectedLDDCSources.insert(source)
                            }
                        }
                    }
                }
                .fixedSize()
            }

            Divider()

            optionPair {
                CapsulePicker(
                    label: "模式",
                    options: LDDCMode.allCases,
                    selection: $selectedMode,
                    displayName: { $0.displayName }
                )
            } trailing: {
                SettingsSwitchRow(title: "包含翻译", isOn: $includeTranslation)
            }
            optionPair {
                SettingsSwitchRow(
                    title: "去除多余信息",
                    isOn: $stripExtraInfo,
                    info: "转换时去掉作词、作曲、制作人员等信息行。"
                )
            } trailing: {
                SettingsSwitchRow(
                    title: "修复时间问题",
                    isOn: $fixTimingProblems,
                    info: "测试功能。转换时修正可能存在的时间错误。"
                )
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    forceRetryUnreliableSourcesForNextSearch = true
                    searchRequestID &+= 1
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .buttonStyle(AppPanelButtonStyle())
                .font(.system(size: SettingsStyleTokens.rowFontSize, weight: .medium))
                .disabled(
                    searchTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSearching
                        || !hasSelectedSource
                )

                if !hasSelectedSource {
                    Text("请选择平台")
                        .settingsDescriptionStyle()
                }
            }
        }
    }

    // MARK: - Results Section

    private var resultsSection: some View {
        SettingsSection("搜索结果", headerTrailing: { resultCountLabel }) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    // Unified results list (no separate sections)
                    ForEach(visibleSearchResults) { candidate in
                        candidateRow(candidate)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 340)
            .appPopupContentBackground()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // The free trailing strip keeps scrolling with the page.
            .trackInfoInnerScrollArea()
        }
    }

    private var resultCountLabel: some View {
        Text("\(visibleSearchResults.count) 条")
            .settingsDescriptionStyle()
    }

    private var splitPanelSection: some View {
        SettingsSection("搜索结果", headerTrailing: { resultCountLabel }) {
            HSplitView {
                splitResultsSection
                    .frame(minWidth: 170, idealWidth: 240, maxWidth: 320)
                    .clipped()
                splitPreviewSection
                    .padding(.leading, 12)
                    .frame(minWidth: 300, idealWidth: 520, maxWidth: .infinity)
                    .clipped()
            }
            .frame(minHeight: 640)
            .clipped()
            .trackInfoInnerScrollArea()
        }
    }

    private var splitResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if !visibleSearchResults.isEmpty {
                    List {
                        // Unified results list; keep already completed sources
                        // visible while slower providers are still running.
                        ForEach(visibleSearchResults) { candidate in
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
                .font(.system(size: 28))
                .foregroundStyle(appFgTertiary)
            Text(hasSelectedSource ? "未找到歌词" : "请选择平台")
                .settingsDescriptionStyle()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appPopupContentBackground()
    }

    private var splitPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if let candidate = selectedCandidate {
                        Text("\(candidate.title) - \(candidate.artist ?? "未知")")
                    } else {
                        Text("预览")
                    }
                }
                .settingsRowLabelStyle()
                .lineLimit(1)

                Spacer(minLength: 8)

                previewActionBar
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
                    previewEditor(reservesScrollGutter: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    
    private var emptyPreviewPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 28))
                .foregroundStyle(appFgTertiary)
            Text("选择歌词查看预览")
                .settingsDescriptionStyle()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appPopupContentBackground()
    }

    /// Two short settings on one line, split like the paired rows in General settings.
    private func optionPair<Leading: View, Trailing: View>(
        @ViewBuilder _ leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            leading()
                .frame(maxWidth: .infinity)
            Divider()
                .frame(height: 18)
                .padding(.top, 2)
            trailing()
                .frame(maxWidth: .infinity)
        }
    }

    private var previewSection: some View {
        SettingsSection("歌词预览", headerTrailing: { previewActionBar }) {
            previewEditor()
        }
    }

    /// Lyrics apply on selection; the button applies edits made in the preview.
    private var previewActionBar: some View {
        HStack(spacing: 10) {
            if autoApplySuccess {
                Label("已应用", systemImage: "checkmark.circle.fill")
                    .font(.system(size: SettingsStyleTokens.descriptionFontSize, weight: .medium))
                    .foregroundStyle(.green)
            }

            Button {
                manualApplyRequestID = UUID()
            } label: {
                Label("应用", systemImage: "checkmark.circle")
            }
            .buttonStyle(AppPanelButtonStyle())
            .font(.system(size: SettingsStyleTokens.rowFontSize, weight: .medium))
            .disabled(isApplying || editableOrig.isEmpty)
        }
    }

    /// The split layout already keeps its own trailing gutter.
    private func previewEditor(reservesScrollGutter: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("原文")
                    .settingsRowLabelStyle()
                TrackInfoTextEditorBox(
                    prompt: nil,
                    text: $editableOrig,
                    height: 240,
                    monospaced: true,
                    reservesScrollGutter: reservesScrollGutter
                )
            }

            if !editableTrans.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("翻译")
                        .settingsRowLabelStyle()
                    TrackInfoTextEditorBox(
                        prompt: nil,
                        text: $editableTrans,
                        height: 140,
                        monospaced: true,
                        reservesScrollGutter: reservesScrollGutter
                    )
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
            let sourceColor = platformColor(candidate.sourceEnum ?? .LRCLIB)

            HStack(spacing: 8) {
                // Fixed-width badge area for consistent text alignment
                Text(candidate.sourceEnum?.displayName ?? candidate.source)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(sourceColor.opacity(colorScheme == .dark ? 0.24 : 0.16), in: Capsule())
                    .foregroundStyle(sourceColor)
                    .frame(width: 64, alignment: .leading)

                // Text content - always starts at same horizontal position
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .font(.system(size: SettingsStyleTokens.rowFontSize, weight: .medium))
                        .foregroundStyle(appFgPrimary)
                        .lineLimit(1)

                    Text(candidateSubtitle(candidate))
                        .font(.system(size: SettingsStyleTokens.descriptionFontSize))
                        .foregroundStyle(appFgSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Score badge - properly normalized 0-100%
                Text(String(format: "%.0f%%", displayScore))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(appFgTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                selectedCandidate?.id == candidate.id
                    ? themeStore.selectionFill
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle()) // Make whole row clickable
        }
        .buttonStyle(.plain)
    }

    private func candidateSubtitle(_ candidate: LDDCCandidate) -> String {
        let artist = candidate.artist ?? "未知"
        guard let album = candidate.album, !album.isEmpty else { return artist }
        return "\(artist) - \(album)"
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: SettingsStyleTokens.descriptionFontSize))
            Spacer()
        }
        .padding(10)
        .appPopupContentBackground(tint: .orange)
    }

    private func noticeBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(appFgSecondary)
            Text(message)
                .font(.system(size: SettingsStyleTokens.descriptionFontSize))
            Spacer()
        }
        .padding(10)
        .appPopupContentBackground()
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
        guard hasSelectedSource, !searchTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
                    stripMetadata: stripExtraInfo,
                    fixTimingIssues: fixTimingProblems
                )
                guard let normalized = LyricsFormatSupport.normalizedTTMLText(converted) else {
                    throw TTMLConversionError.conversionFailed("LDDC 转换结果 TTML 结构无效")
                }
                ttml = normalized
                Self.logger.info("[LyricsApply] LDDC converted to TTML with translation")
            } else {
                let converted = try await TTMLConverter.shared.convertToTTML(
                    rawLyrics: origLyrics,
                    stripMetadata: stripExtraInfo,
                    fixTimingIssues: fixTimingProblems
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
    
    /// Off chips stay neutral gray; a selected chip lights up in its source color.
    private func sourceChip(
        _ source: LDDCSource,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let color = platformColor(source)
        return Button(action: action) {
            Text(source.displayName)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? color : appFgTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(minHeight: 24)
                .background(
                    isSelected
                        ? color.opacity(colorScheme == .dark ? 0.24 : 0.16)
                        : appFgSecondary.opacity(0.08),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(isSelected ? "已选择" : "未选择"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func platformColor(_ source: LDDCSource) -> Color {
        themeStore.semanticPalette.lyricsSourceColor(source, colorScheme: colorScheme)
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
