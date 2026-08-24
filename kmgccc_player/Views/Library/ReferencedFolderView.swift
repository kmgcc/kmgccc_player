import AppKit
import SwiftUI

/// A deliberately small, referenced-library-only map of physical sources to
/// playlists.  It is a projection of the source descriptors and locator
/// memberships; it does not become a second owner of library data.
struct ReferencedFolderView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @ObservedObject var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var sources: [ReferencedSourceDescriptor] = []
    /// Bumped by `reload()` so the derived-content memo invalidates when
    /// descriptors (bindings, excluded paths, status) change.
    @State private var sourcesRevision = 0
    @State private var selectedSourceID: UUID?
    @State private var folderSelection: FolderSelection = .all
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var folderSearchText = ""
    /// Explicit expand/collapse overrides keyed by "sourceID|path". Missing
    /// keys fall back to the default rule: depth-0 roots expanded.
    @State private var folderExpansionOverrides: [String: Bool] = [:]
    @State private var contentMemo = FolderContentMemo()

    private enum FolderSelection: Hashable {
        case all
        case folder(String)
        case standalone
    }

    private struct FolderEntry: Identifiable, Hashable {
        let path: String
        let count: Int
        let depth: Int
        let isExcluded: Bool

        var id: String { path }
    }

    /// Body-eval memo for the folder projections. Stored as a reference and
    /// mutated in place so recomputation happens at most once per input
    /// change instead of three-plus times per body evaluation.
    private final class FolderContentMemo {
        struct Key: Equatable {
            let revision: Int
            let sourcesRevision: Int
            let isLoading: Bool
            let trackCount: Int
            let sourceID: UUID?
            let selection: FolderSelection
            let searchText: String
        }

        var key: Key?
        var sourceTracks: [Track] = []
        var standaloneTrackCount = 0
        var folderEntries: [FolderEntry] = []
        var directChildCounts: [String: Int] = [:]
        var visibleTracks: [Track] = []

        func reset() {
            sourceTracks = []
            standaloneTrackCount = 0
            folderEntries = []
            directChildCounts = [:]
            visibleTracks = []
        }
    }

    var body: some View {
        HSplitView {
            sourceTree
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 330)

            detailPane
                .frame(minWidth: 430, idealWidth: 620)
        }
        .task(id: appSession.activeLibraryBinding.generation) {
            await reload()
        }
    }

    private var sourceTree: some View {
        List {
            Section("资料库来源") {
                if sources.isEmpty {
                    Text("还没有绑定文件夹")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(sources) { source in
                        Button {
                            selectedSourceID = source.id
                            folderSelection = .all
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: source.mode == .directory ? "folder" : "music.note")
                                    .foregroundStyle(sourceStatusColor(source))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.displayName)
                                        .lineLimit(1)
                                    Text(source.lastKnownPath)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                scanIndicator(for: source)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(source.id)
                        .listRowBackground(
                            selectedSourceID == source.id
                                ? themeStore.selectionFill
                                : Color.clear
                        )
                    }
                }
            }

            if selectedSource != nil {
                Section("文件夹") {
                    TextField("按路径筛选", text: $folderSearchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    folderRow(title: "全部歌曲", systemImage: "music.note.list", selection: .all)
                    ForEach(visibleFolderEntries) { entry in
                        folderRow(
                            title: entry.path.isEmpty ? "根目录" : entry.path,
                            systemImage: "folder",
                            detail: "\(entry.count) 首",
                            selection: .folder(entry.path),
                            depth: entry.depth,
                            isExcluded: entry.isExcluded,
                            isBranch: directChildCount(for: entry) > 0,
                            isExpanded: isFolderExpanded(entry),
                            onToggleChevron: { toggleFolderExpanded(entry) }
                        )
                    }
                    if memoized.standaloneTrackCount > 0 {
                        folderRow(
                            title: "单独添加的歌曲",
                            systemImage: "music.note",
                            detail: "\(memoized.standaloneTrackCount) 首",
                            selection: .standalone
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func folderRow(
        title: String,
        systemImage: String,
        detail: String? = nil,
        selection: FolderSelection,
        depth: Int = 0,
        isExcluded: Bool = false,
        isBranch: Bool = false,
        isExpanded: Bool = true,
        onToggleChevron: (() -> Void)? = nil
    ) -> some View {
        Button {
            folderSelection = selection
        } label: {
            HStack(spacing: 8) {
                if isBranch {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 11)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .onTapGesture { onToggleChevron?() }
                }
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isExcluded {
                    Text("已排除")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
            .padding(.leading, CGFloat(depth) * 12)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            folderSelection == selection
                ? themeStore.selectionFill
                : Color.clear
        )
        .contextMenu {
            if case let .folder(path) = selection,
               !path.isEmpty,
               let source = selectedSource {
                let excludedPath = source.excludedRelativePaths
                    .filter { path == $0 || path.hasPrefix($0 + "/") }
                    .min { $0.count < $1.count }
                Button(excludedPath == nil ? "排除此文件夹" : "取消排除文件夹") {
                    setExcludedPath(
                        source,
                        path: excludedPath ?? path,
                        excluded: excludedPath == nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let source = selectedSource {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceHeader(source)
                    sourceStatusNotice(source)
                    playlistRelations(source)
                    trackSection(source)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label("选择一个来源", systemImage: "folder.badge.gearshape")
            } description: {
                Text("左侧显示原位资料库的文件夹来源；选择后可以查看歌曲和播放列表的关系。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sourceHeader(_ source: ReferencedSourceDescriptor) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: source.mode == .directory ? "folder.fill" : "music.note")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(themeStore.accentColor)
                .frame(width: 42, height: 42)
                .background(themeStore.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 4) {
                Text(source.displayName)
                    .font(.title3.weight(.semibold))
                Text(source.lastKnownPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let lastScan = source.lastScan {
                    Text("上次扫描：\(lastScan.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button {
                    reveal(source)
                } label: {
                    Label("在访达中显示", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)

                Button {
                    refresh(source)
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
    }

    @ViewBuilder
    private func sourceStatusNotice(_ source: ReferencedSourceDescriptor) -> some View {
        HStack(spacing: 9) {
            Image(systemName: sourceStatusIcon(source))
                .foregroundStyle(sourceStatusColor(source))
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceStatusTitle(source))
                    .font(.callout.weight(.medium))
                Text(sourceStatusDetail(source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func trackSection(_ source: ReferencedSourceDescriptor) -> some View {
        let tracks = memoized.visibleTracks
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(folderSelectionTitle)
                    .font(.headline)
                Spacer()
                Text("\(tracks.count) 首")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if tracks.isEmpty {
                Text("这个位置目前没有歌曲")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        HStack(spacing: 10) {
                            Image(systemName: track.availability.isPlayable ? "music.note" : "exclamationmark.triangle")
                                .foregroundStyle(track.availability.isPlayable ? themeStore.accentColor : .orange)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title.isEmpty ? "未命名歌曲" : track.title)
                                    .lineLimit(1)
                                Text(track.artist.isEmpty ? "未知艺人" : track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if let path = membershipPath(track, sourceID: source.id) {
                                Text(path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 220, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .contextMenu { trackRowMenu(track, source: source) }
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trackRowMenu(_ track: Track, source: ReferencedSourceDescriptor) -> some View {
        Button {
            playbackCoordinator.playTrack(track, inQueueFrom: memoized.visibleTracks)
        } label: {
            Label("播放", systemImage: "play")
        }

        if playbackCoordinator.canInsertTracksAfterCurrent {
            Button {
                if playbackCoordinator.insertTracksAfterCurrent([track]) > 0 {
                    appSession.uiState.showSidebarNotice("已加入下一首")
                }
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }

        Divider()

        Button {
            revealTrack(track, source: source)
        } label: {
            Label("在访达中显示", systemImage: "arrow.up.forward.app")
        }
    }

    private func playlistRelations(_ source: ReferencedSourceDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("播放列表关系")
                    .font(.headline)
                Spacer()
                Menu {
                    let boundIDs = Set(source.playlistBindings.map(\.playlistID))
                    let candidates = libraryVM.playlists.filter { !boundIDs.contains($0.id) }
                    if candidates.isEmpty {
                        Text("没有可绑定的播放列表")
                    } else {
                        ForEach(candidates) { playlist in
                            Button(playlist.name) {
                                bind(source, playlistID: playlist.id)
                            }
                        }
                    }
                } label: {
                    Label("绑定播放列表", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .disabled(isWorking)
            }

            if source.playlistBindings.isEmpty {
                Text("这个来源只会出现在“所有歌曲”中，尚未绑定播放列表。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(source.playlistBindings) { binding in
                    HStack(spacing: 10) {
                        Image(systemName: "music.note.list")
                            .foregroundStyle(themeStore.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlistName(for: binding.playlistID))
                            if let relativePath = binding.relativePath, !relativePath.isEmpty {
                                Text("仅同步 \(relativePath)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("同步这个来源中的全部歌曲")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("解除关系") {
                            unbind(source, bindingID: binding.id)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(isWorking)
                    }
                    .padding(.vertical, 6)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, 4)
    }

    private var selectedSource: ReferencedSourceDescriptor? {
        sources.first { $0.id == selectedSourceID }
    }

    // MARK: - Derived Content Memo

    private var memoized: FolderContentMemo {
        let key = FolderContentMemo.Key(
            revision: libraryVM.refreshTrigger,
            sourcesRevision: sourcesRevision,
            isLoading: libraryVM.isLoading,
            trackCount: libraryVM.totalTrackCount,
            sourceID: selectedSourceID,
            selection: folderSelection,
            searchText: folderSearchText
        )
        if contentMemo.key == key {
            return contentMemo
        }
        contentMemo.reset()
        contentMemo.key = key
        if let source = selectedSource {
            contentMemo.sourceTracks = computeSourceTracks(source)
            contentMemo.folderEntries = computeFolderEntries(
                source,
                tracks: contentMemo.sourceTracks
            )
            var childCounts: [String: Int] = [:]
            for entry in contentMemo.folderEntries where entry.depth > 0 {
                let parent = entry.path.split(separator: "/").dropLast().joined(separator: "/")
                childCounts[parent, default: 0] += 1
            }
            contentMemo.directChildCounts = childCounts
        }
        contentMemo.standaloneTrackCount = computeStandaloneTrackCount()
        contentMemo.visibleTracks = computeVisibleTracks()
        return contentMemo
    }

    /// Entries currently shown in the tree: search matches ignore collapse;
    /// otherwise an entry is visible only when every ancestor is expanded.
    private var visibleFolderEntries: [FolderEntry] {
        let entries = memoized.folderEntries
        guard !folderSearchText.isEmpty else {
            return entries.filter { ancestorsExpanded(for: $0) }
        }
        return entries.filter { $0.path.localizedCaseInsensitiveContains(folderSearchText) }
    }

    private func directChildCount(for entry: FolderEntry) -> Int {
        memoized.directChildCounts[entry.path] ?? 0
    }

    private func expansionKey(_ entry: FolderEntry) -> String {
        "\(selectedSourceID?.uuidString ?? "")|\(entry.path)"
    }

    private func isFolderExpanded(_ entry: FolderEntry) -> Bool {
        folderExpansionOverrides[expansionKey(entry)] ?? (entry.depth == 0)
    }

    private func toggleFolderExpanded(_ entry: FolderEntry) {
        withAnimation(.snappy(duration: 0.18)) {
            folderExpansionOverrides[expansionKey(entry)] = !isFolderExpanded(entry)
        }
    }

    private func ancestorsExpanded(for entry: FolderEntry) -> Bool {
        guard entry.depth > 0 else { return true }
        var components = entry.path.split(separator: "/").map(String.init)
        let sourceID = selectedSourceID
        while !components.isEmpty {
            components.removeLast()
            let ancestorPath = components.joined(separator: "/")
            let ancestorKey = "\(sourceID?.uuidString ?? "")|\(ancestorPath)"
            let defaultExpanded = components.count == 1
            if folderExpansionOverrides[ancestorKey] ?? defaultExpanded {
                continue
            }
            return false
        }
        return true
    }

    private func computeFolderEntries(
        _ source: ReferencedSourceDescriptor,
        tracks: [Track]
    ) -> [FolderEntry] {
        var trackIDsByFolder: [String: Set<UUID>] = [:]

        func addFolderAndAncestors(_ folder: String, trackID: UUID?) {
            guard !folder.isEmpty else { return }
            let components = folder.split(separator: "/").map(String.init)
            guard !components.isEmpty else { return }
            for end in 1...components.count {
                let path = components.prefix(end).joined(separator: "/")
                if let trackID {
                    trackIDsByFolder[path, default: []].insert(trackID)
                } else if trackIDsByFolder[path] == nil {
                    trackIDsByFolder[path] = []
                }
            }
        }

        for track in tracks {
            for path in membershipPaths(track, sourceID: source.id) {
                addFolderAndAncestors(folderPath(for: path), trackID: track.id)
            }
        }
        for excludedPath in source.excludedRelativePaths {
            addFolderAndAncestors(excludedPath, trackID: nil)
        }

        return trackIDsByFolder.map { pair in
            let path = pair.key
            return FolderEntry(
                path: path,
                count: pair.value.count,
                depth: path.split(separator: "/").count - 1,
                isExcluded: source.excludedRelativePaths.contains { excluded in
                    path == excluded || path.hasPrefix(excluded + "/")
                }
            )
        }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func computeStandaloneTrackCount() -> Int {
        libraryVM.allTracks.filter { track in
            guard case let .referenced(locator) = track.mediaLocator else { return false }
            return locator.allSourceMemberships.isEmpty
        }.count
    }

    private var folderSelectionTitle: String {
        switch folderSelection {
        case .all: return "来源歌曲"
        case .folder(let path): return path.isEmpty ? "根目录" : path
        case .standalone: return "单独添加的歌曲"
        }
    }

    private func computeSourceTracks(_ source: ReferencedSourceDescriptor) -> [Track] {
        libraryVM.allTracks.filter { track in
            guard case let .referenced(locator) = track.mediaLocator else { return false }
            return locator.containsSource(source.id)
        }
    }

    private func computeVisibleTracks() -> [Track] {
        guard let source = selectedSource else { return [] }
        let tracks: [Track]
        switch folderSelection {
        case .all:
            tracks = memoized.sourceTracks
        case .folder(let folder):
            tracks = memoized.sourceTracks.filter { track in
                membershipPaths(track, sourceID: source.id).contains { path in
                    let folderPath = folderPath(for: path)
                    return folderPath == folder || folderPath.hasPrefix(folder + "/")
                }
            }
        case .standalone:
            tracks = libraryVM.allTracks.filter { track in
                guard case let .referenced(locator) = track.mediaLocator else { return false }
                return locator.allSourceMemberships.isEmpty
            }
        }
        return tracks.sorted {
            let leftPath = membershipPath($0, sourceID: source.id) ?? ""
            let rightPath = membershipPath($1, sourceID: source.id) ?? ""
            if leftPath != rightPath {
                return leftPath.localizedStandardCompare(rightPath) == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func membershipPaths(_ track: Track, sourceID: UUID) -> [String] {
        guard case let .referenced(locator) = track.mediaLocator else { return [] }
        return locator.allSourceMemberships
            .filter { $0.sourceID == sourceID }
            .map(\.relativePath)
    }

    private func membershipPath(_ track: Track, sourceID: UUID) -> String? {
        membershipPaths(track, sourceID: sourceID).first
    }

    private func folderPath(for relativePath: String) -> String {
        let url = URL(fileURLWithPath: relativePath)
        let folder = url.deletingLastPathComponent().path
        return folder == "." ? "" : folder
    }

    private func playlistName(for playlistID: UUID) -> String {
        libraryVM.playlists.first { $0.id == playlistID }?.name ?? "已删除的播放列表"
    }

    private func scanIndicator(for source: ReferencedSourceDescriptor) -> some View {
        Group {
            switch appSession.referencedSourceScanStatesSnapshot[source.id] ?? .idle {
            case .idle:
                Circle().fill(sourceStatusColor(source)).frame(width: 7, height: 7)
            case .scanning:
                ProgressView().controlSize(.mini)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 14, height: 14)
    }

    private func sourceStatusTitle(_ source: ReferencedSourceDescriptor) -> String {
        switch source.status {
        case .available: return "来源可用"
        case .stale: return "来源需要重新连接"
        case .permissionDenied: return "来源权限失效"
        case .offline: return "来源暂时离线"
        }
    }

    private func sourceStatusDetail(_ source: ReferencedSourceDescriptor) -> String {
        switch appSession.referencedSourceScanStatesSnapshot[source.id] ?? .idle {
        case .scanning: return "正在扫描文件变化，歌曲关系会保持不变。"
        case .failed: return "最近一次扫描失败；可以重试，或到设置中重新连接来源。"
        case .idle:
            return source.status == .available
                ? "来源中的文件会自动同步到所有歌曲。"
                : "歌曲仍保留在资料库中，恢复来源后会继续可用。"
        }
    }

    private func sourceStatusIcon(_ source: ReferencedSourceDescriptor) -> String {
        switch source.status {
        case .available: return "checkmark.circle.fill"
        case .stale, .permissionDenied: return "lock.trianglebadge.exclamationmark"
        case .offline: return "externaldrive.badge.xmark"
        }
    }

    private func sourceStatusColor(_ source: ReferencedSourceDescriptor) -> Color {
        switch source.status {
        case .available: return .green
        case .stale, .permissionDenied: return .orange
        case .offline: return .secondary
        }
    }

    private func reload() async {
        do {
            let loaded = try await appSession.referencedSources()
            sources = loaded
            sourcesRevision += 1
            if selectedSourceID == nil || !loaded.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = loaded.first?.id
                folderSelection = .all
            }
        } catch {
            errorMessage = "无法读取资料库来源。"
        }
    }

    private func reveal(_ source: ReferencedSourceDescriptor) {
        guard FinderRevealHelper.reveal(
            path: source.lastKnownPath,
            bookmarkData: source.rootBookmarkData
        ) else {
            appSession.uiState.showSidebarNotice(
                "来源位置无法访问，可能已被移动或删除。",
                style: .warning
            )
            return
        }
    }

    private func revealTrack(_ track: Track, source: ReferencedSourceDescriptor) {
        guard let relativePath = membershipPath(track, sourceID: source.id),
              !relativePath.isEmpty else { return }
        let absolutePath = (source.lastKnownPath as NSString)
            .appendingPathComponent(relativePath)
        guard FinderRevealHelper.reveal(path: absolutePath) else {
            appSession.uiState.showSidebarNotice(
                "歌曲文件不在预期位置，可能已被移动或删除。",
                style: .warning
            )
            return
        }
    }

    private func refresh(_ source: ReferencedSourceDescriptor) {
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                _ = try await appSession.refreshReferencedSource(id: source.id)
                await reload()
            } catch {
                errorMessage = "无法重新扫描这个来源。"
            }
        }
    }

    private func bind(_ source: ReferencedSourceDescriptor, playlistID: UUID) {
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await appSession.bindReferencedSource(id: source.id, to: playlistID)
                await reload()
            } catch {
                errorMessage = "无法绑定播放列表。"
            }
        }
    }

    private func unbind(_ source: ReferencedSourceDescriptor, bindingID: UUID) {
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                _ = try await appSession.unbindReferencedSource(id: source.id, bindingID: bindingID)
                await reload()
            } catch {
                errorMessage = "无法解除播放列表关系。"
            }
        }
    }

    private func setExcludedPath(
        _ source: ReferencedSourceDescriptor,
        path: String,
        excluded: Bool
    ) {
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await appSession.setReferencedSourceExcludedPath(
                    id: source.id,
                    relativePath: path,
                    excluded: excluded
                )
                await reload()
            } catch {
                errorMessage = excluded
                    ? "无法排除这个文件夹。"
                    : "无法取消排除这个文件夹。"
            }
        }
    }
}
