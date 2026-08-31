import AppKit
import SwiftUI

struct MusicSettingsView: View {
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(LibraryViewModel.self) private var libraryVM

    @State private var registry = MusicLibraryRegistry()
    @State private var sources: [ReferencedSourceDescriptor] = []
    @State private var settings = LibraryScopedSettings()
    @State private var errorMessage: String?
    @State private var pendingLibraryRemoval: MusicLibraryBookmark?
    @State private var pendingSourceRemoval: ReferencedSourceDescriptor?
    @State private var isAddingMusic = false
    @State private var pendingImportURLs: [URL] = []
    @State private var isImportSourceSelectionPresented = false
    @State private var isSourceListExpanded = false
    @State private var isMissingListExpanded = false
    @State private var isDuplicateReviewPresented = false

    /// Pushed by AppSessionHost on scan-state transitions; no polling here.
    private var sourceScanStates: [UUID: ReferencedSourceScanState] {
        appSession.referencedSourceScanStatesSnapshot
    }

    /// Long source lists collapse to this many rows until expanded.
    private static let collapsedSourceCount = 6

    private var visibleSources: [ReferencedSourceDescriptor] {
        isSourceListExpanded ? sources : Array(sources.prefix(Self.collapsedSourceCount))
    }

    private var flow: LibrarySetupViewModel { appSession.librarySetupFlow }
    private var activeContext: LibraryContext? { appSession.activeLibraryBinding.context }
    private var activeMode: MusicLibraryMode? { activeContext?.mode }
    private var isWorking: Bool { flow.operation == .working }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("音乐存储方式") {
                HStack(spacing: 10) {
                    Text("当前模式")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(storageModeDisplayTitle)
                        .font(.callout.weight(.medium))
                }
                .accessibilityElement(children: .combine)
            }

            librarySection
            libraryDiagnosticsSection

            if activeMode == .referenced {
                sourceSection
                deletePolicySection
                missingTracksSection
            }
        }
        .task(id: appSession.activeLibraryBinding.generation) {
            await reload()
        }
        .onChange(of: flow.presentation) { _, presentation in
            guard presentation != .none else { return }
            LibrarySetupPanelPresenter.present(appSession: appSession) { await reload() }
        }
        .sheet(isPresented: $isImportSourceSelectionPresented) {
            let urls = pendingImportURLs
            LibraryImportSourceSelectionSheet(
                entries: LibraryImportSourceEntry.makeEntries(from: urls)
            ) { entries in
                startImport(urls: urls, playlistSourceEntries: entries)
            }
        }
        .sheet(isPresented: $isDuplicateReviewPresented) {
            LibraryDuplicateReviewView(snapshot: libraryVM.diagnostics)
        }
        .confirmationDialog(
            "移到废纸篓？",
            isPresented: Binding(get: { pendingLibraryRemoval != nil }, set: { if !$0 { pendingLibraryRemoval = nil } })
        ) {
            Button("移到废纸篓", role: .destructive) { removePendingLibrary() }
            Button("取消", role: .cancel) { pendingLibraryRemoval = nil }
        } message: {
            if let library = pendingLibraryRemoval {
                let dataMessage = library.modeProjection == .managed
                    ? "资料库中的音乐和数据将移到废纸篓。"
                    : "资料库数据将移到废纸篓，原位置的音乐不会删除。"
                Text("资料库：\(library.displayName)\n位置：\(library.lastKnownPath)\n\(dataMessage)")
            }
        }
        .confirmationDialog(
            "移除来源？",
            isPresented: Binding(get: { pendingSourceRemoval != nil }, set: { if !$0 { pendingSourceRemoval = nil } })
        ) {
            Button("移除来源", role: .destructive) { removePendingSource() }
            Button("取消", role: .cancel) { pendingSourceRemoval = nil }
        } message: {
            Text("其中的歌曲将从资料库移除，原文件不会删除。")
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var storageModeDisplayTitle: String {
        activeMode?.dialogDisplayTitle ?? "未打开资料库"
    }

    private var librarySection: some View {
        SettingsSection("资料库") {
            VStack(spacing: 0) {
                HStack {
                    Text("已添加资料库").font(.callout.weight(.medium))
                    Spacer()
                    Menu {
                        Button("新建资料库…") { flow.present(.setup(.referenced)) }
                        Button("打开资料库…") { openLibraryPanel() }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .help("添加资料库")
                    .accessibilityLabel("添加资料库")
                    .disabled(isWorking || isAddingMusic)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                ForEach(Array(registry.libraries.enumerated()), id: \.element.id) { index, library in
                    libraryRow(library)
                    if index < registry.libraries.count - 1 { Divider().padding(.leading, 12) }
                }
            }
        }
    }

    private func revealLibrary(_ library: MusicLibraryBookmark) {
        guard FinderRevealHelper.reveal(path: library.lastKnownPath, bookmarkData: library.rootBookmarkData) else {
            appSession.uiState.showSidebarNotice(
                "资料库位置无法访问，可能已被移动或删除。",
                style: .warning
            )
            return
        }
    }

    private func libraryRow(_ library: MusicLibraryBookmark) -> some View {
        HStack(spacing: 10) {
            Button {
                open(library)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(library.displayName).lineLimit(1).truncationMode(.middle)
                        if library.id == activeContext?.id {
                            Text("当前").font(.caption2).foregroundStyle(themeStore.accentColor)
                        }
                    }
                    Text(library.lastKnownPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(library.lastKnownPath)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Menu {
                Button("在访达中显示") { revealLibrary(library) }
                Divider()
                Button("移到废纸篓…", role: .destructive) { pendingLibraryRemoval = library }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("资料库操作")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sourceSection: some View {
        SettingsSection("音乐来源") {
            VStack(spacing: 0) {
                HStack {
                    Text("已添加来源")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if isAddingMusic {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在添加音乐")
                    }
                    Button {
                        refreshSources(sourceID: nil)
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("完整扫描全部来源")
                    .accessibilityLabel("完整扫描全部来源")
                    .disabled(isWorking || isAddingMusic || sources.isEmpty || isFullScanRunning)
                    Button {
                        addMusicPanel()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("添加音乐")
                    .accessibilityLabel("添加音乐")
                    .disabled(isWorking || isAddingMusic)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                if sources.isEmpty {
                    Text("尚未添加来源")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                ForEach(Array(visibleSources.enumerated()), id: \.element.id) { index, source in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(source.displayName).lineLimit(1).truncationMode(.middle)
                                if source.mode == .file {
                                    Text("单文件")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(sourceRowStatus(source))
                                    .font(.caption2)
                                    .foregroundStyle(
                                        source.status == .available
                                            && sourceScanStates[source.id] != .failed
                                            ? Color.secondary
                                            : Color.orange
                                    )
                            }
                            Text(source.lastKnownPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if sourceScanStates[source.id] == .scanning {
                            ProgressView().controlSize(.small).accessibilityLabel("正在扫描")
                        } else if sourceScanStates[source.id] == .failed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityLabel("扫描失败")
                        }

                        Menu {
                            Button("重新扫描") { refreshSources(sourceID: source.id) }
                            Button("重新连接…") {
                                guard let libraryID = activeContext?.id else { return }
                                flow.present(.sourceReconnect(
                                    libraryID: libraryID,
                                    sourceIDs: [source.id]
                                ))
                            }
                            Divider()
                            Button("移除来源…", role: .destructive) { pendingSourceRemoval = source }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .help("来源操作")
                        .accessibilityLabel("\(source.displayName)来源操作")
                    }
                    .id(source.id)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if index < visibleSources.count - 1 { Divider().padding(.leading, 12) }
                }

                if sources.count > Self.collapsedSourceCount {
                    Divider().padding(.leading, 12)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSourceListExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isSourceListExpanded ? 90 : 0))
                            Text(isSourceListExpanded ? "收起" : "显示全部 \(sources.count) 个来源")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var libraryDiagnosticsSection: some View {
        let summary = libraryVM.diagnostics.summary
        return SettingsSection("资料库概览") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    diagnosticMetric("歌曲", value: "\(summary.totalTracks)", color: themeStore.accentColor)
                    diagnosticMetric("可播放", value: "\(summary.playableTracks)", color: .green)
                    diagnosticMetric("总时长", value: formattedDuration(summary.totalDuration), color: .secondary)
                }

                Divider()

                HStack(spacing: 14) {
                    statusMetric("文件丢失", count: summary.missingTracks, color: .orange)
                    statusMetric("来源离线", count: summary.offlineTracks, color: .secondary)
                    statusMetric("无权限", count: summary.permissionDeniedTracks, color: .orange)
                    statusMetric("待检查", count: summary.checkingTracks, color: .secondary)
                }

                if !summary.topFormats.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("格式")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(Array(summary.topFormats.prefix(4).enumerated()), id: \.offset) { _, item in
                            HStack(spacing: 8) {
                                Text(item.format.uppercased())
                                    .font(.caption.monospaced())
                                    .frame(width: 54, alignment: .leading)
                                ProgressView(
                                    value: Double(item.count),
                                    total: Double(max(summary.totalTracks, 1))
                                )
                                .tint(themeStore.accentColor)
                                Text("\(item.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                }

                if !libraryVM.diagnostics.duplicateGroups.isEmpty {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.orange)
                        Text("发现 \(libraryVM.diagnostics.duplicateGroups.count) 组重复候选")
                            .font(.callout)
                        Spacer()
                        Button("查看") { isDuplicateReviewPresented = true }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding(12)
        }
    }

    private func diagnosticMetric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusMetric(_ title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(count)")
                .font(.callout.weight(.medium))
                .foregroundStyle(count == 0 ? Color.secondary : color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 60 { return "\(totalMinutes) 分钟" }
        return "\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分钟"
    }

    private var deletePolicySection: some View {
        SettingsSection("删除歌曲时") {
            Picker("删除歌曲时", selection: Binding(
                get: { settings.referencedTrackDeletePolicy },
                set: { policy in
                    guard let libraryID = activeContext?.id else { return }
                    let previousPolicy = settings.referencedTrackDeletePolicy
                    settings.referencedTrackDeletePolicy = policy
                    Task {
                        do {
                            try await appSession.setReferencedTrackDeletePolicy(
                                policy,
                                libraryID: libraryID
                            )
                        } catch {
                            guard activeContext?.id == libraryID else { return }
                            if settings.referencedTrackDeletePolicy == policy {
                                settings.referencedTrackDeletePolicy = previousPolicy
                            }
                            errorMessage = "无法保存删除方式。"
                        }
                    }
                }
            )) {
                Text("仅从资料库移除").tag(ReferencedTrackDeletePolicy.onlyLibrary)
                Text("将原文件移到废纸篓").tag(ReferencedTrackDeletePolicy.recycleSource)
            }
            .pickerStyle(.radioGroup)
        }
    }

    /// Tracks playback cannot reach: source file deleted (.missing), the
    /// whole source offline (.volumeUnavailable) or unreadable
    /// (.permissionDenied). Matches the greyed-row state in track lists.
    private var unavailableTracks: [Track] {
        libraryVM.allTracks.filter {
            $0.availability == .missing
                || $0.availability == .volumeUnavailable
                || $0.availability == .permissionDenied
        }
    }

    private var missingTracksSection: some View {
        SettingsSection("失效歌曲") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(unavailableTracks.isEmpty
                             ? "没有失效歌曲"
                             : "\(unavailableTracks.count) 首歌曲暂时不可用")
                            .font(.callout)
                        Text("失效歌曲在列表中显示为灰色。来源暂时离线或权限失效时，请先重新连接来源；恢复后歌曲会继续保留。")
                            .settingsDescriptionStyle()
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if !unavailableTracks.isEmpty {
                    Divider()

                    ForEach(Array(visibleUnavailableTracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("失效")
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(track.title).lineLimit(1).truncationMode(.middle)
                                    Text(unavailableReasonLabel(track.availability))
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                Text(track.artist.isEmpty ? "未知艺术家" : track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(track.id)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        if index < visibleUnavailableTracks.count - 1 { Divider().padding(.leading, 12) }
                    }

                    if unavailableTracks.count > Self.collapsedSourceCount {
                        Divider().padding(.leading, 12)
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isMissingListExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(isMissingListExpanded ? 90 : 0))
                                Text(isMissingListExpanded ? "收起" : "显示全部 \(unavailableTracks.count) 首")
                                    .font(.callout)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private var visibleUnavailableTracks: [Track] {
        isMissingListExpanded ? unavailableTracks : Array(unavailableTracks.prefix(Self.collapsedSourceCount))
    }

    private func unavailableReasonLabel(_ availability: TrackAvailability) -> String {
        switch availability {
        case .missing: return "文件丢失"
        case .volumeUnavailable: return "来源离线"
        case .permissionDenied: return "无权限"
        default: return "不可用"
        }
    }

    private func reload() async {
        let targetGeneration = appSession.activeLibraryBinding.generation
        let targetLibraryID = activeContext?.id
        let loadedRegistry = await appSession.musicLibraryRegistrySnapshot()
        do {
            let loadedSources = try await appSession.referencedSources()
            let loadedSettings = try await appSession.libraryScopedSettings()
            guard appSession.activeLibraryBinding.generation == targetGeneration,
                  activeContext?.id == targetLibraryID else { return }
            registry = loadedRegistry
            sources = loadedSources
            settings = loadedSettings
        } catch {
            guard appSession.activeLibraryBinding.generation == targetGeneration,
                  activeContext?.id == targetLibraryID else { return }
            errorMessage = "无法读取资料库设置。"
        }
    }

    private func open(_ library: MusicLibraryBookmark) {
        guard library.id != activeContext?.id else { return }
        let operation = flow.beginOperation()
        Task {
            do {
                let sourceIDs = try await appSession.activateRegisteredLibrary(id: library.id)
                guard flow.isCurrentOperation(operation) else { return }
                if sourceIDs.isEmpty {
                    flow.completeAndDismiss()
                } else {
                    flow.present(.sourceReconnect(libraryID: library.id, sourceIDs: sourceIDs))
                }
                await reload()
            } catch RegisteredLibraryActivationError.reconnectRequired {
                guard flow.isCurrentOperation(operation) else { return }
                flow.present(.reconnectRequired(libraryID: library.id, mode: library.modeProjection))
            } catch {
                guard flow.isCurrentOperation(operation) else { return }
                flow.fail("无法打开资料库。")
                errorMessage = "无法打开资料库。"
            }
        }
    }

    private func openLibraryPanel() {
        chooseDirectory(prompt: "打开") { url, access in
            let operation = flow.beginOperation()
            Task {
                defer { access.release() }
                do {
                    let sourceIDs = try await appSession.openMusicLibrary(at: url)
                    guard flow.isCurrentOperation(operation) else { return }
                    if let libraryID = appSession.activeLibraryBinding.context?.id,
                       !sourceIDs.isEmpty {
                        flow.present(.sourceReconnect(libraryID: libraryID, sourceIDs: sourceIDs))
                    } else {
                        flow.completeAndDismiss()
                    }
                    await reload()
                }
                catch {
                    guard flow.isCurrentOperation(operation) else { return }
                    flow.fail("无法打开资料库。")
                    errorMessage = "所选位置不是可用资料库。"
                }
            }
        }
    }

    private func chooseDirectory(
        prompt: String,
        completion: @escaping (URL, LibraryInitialImportSelection) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.begin { result in
            if result == .OK, let url = panel.url {
                completion(url, LibraryInitialImportSelection(urls: [url]))
            }
        }
    }

    private func addMusicPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = FileImportService.supportedUTTypes
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "添加"
        panel.begin { result in
            guard result == .OK, !panel.urls.isEmpty else { return }
            pendingImportURLs = panel.urls
            isImportSourceSelectionPresented = true
        }
    }

    private func startImport(
        urls: [URL],
        playlistSourceEntries: [LibraryImportSourceEntry]
    ) {
        guard !urls.isEmpty else { return }
        let selection = LibraryInitialImportSelection(
            urls: urls,
            playlistSourceEntries: playlistSourceEntries
        )
        pendingImportURLs = []
        isAddingMusic = true
        guard let session = appSession.activeLibraryBinding.activeSession else {
            selection.release()
            isAddingMusic = false
            errorMessage = "当前没有可用的音乐资料库。"
            return
        }
        let libraryID = session.context.id
        Task {
            defer {
                selection.release()
                isAddingMusic = false
            }
            do {
                let result = try await session.runLibraryOperation {
                    try await session.importInitialSelection(selection)
                }
                guard appSession.activeLibraryBinding.context?.id == libraryID else { return }
                if result.isPartial {
                    appSession.uiState.showSidebarNotice(
                        "部分音乐未导入",
                        style: .warning,
                        actionTitle: "打开设置"
                    )
                } else if result.imported > 0 {
                    appSession.uiState.showSidebarNotice("新增 \(result.imported) 首歌曲")
                }
                await reload()
            } catch {
                guard appSession.activeLibraryBinding.context?.id == libraryID else { return }
                errorMessage = "未能添加所选音乐。"
                await reload()
            }
        }
    }

    private func removePendingLibrary() {
        guard let library = pendingLibraryRemoval else { return }
        pendingLibraryRemoval = nil
        let operation = flow.beginOperation()
        Task {
            let latestRegistry = await appSession.musicLibraryRegistrySnapshot()
            guard let latest = latestRegistry.library(id: library.id),
                  latest.lastKnownPath == library.lastKnownPath,
                  latest.modeProjection == library.modeProjection else {
                guard flow.isCurrentOperation(operation) else { return }
                flow.fail("资料库列表已变化，请重新加载后再操作。")
                errorMessage = "资料库列表已变化，未执行删除。"
                await reload()
                return
            }
            do {
                try await appSession.removeMusicLibrary(id: library.id)
                guard flow.isCurrentOperation(operation) else { return }
                flow.completeAndDismiss()
                await reload()
            } catch {
                guard flow.isCurrentOperation(operation) else { return }
                flow.fail("无法移到废纸篓。")
                errorMessage = "资料库没有删除：\(error.localizedDescription)"
            }
        }
    }

    private func removePendingSource() {
        guard let source = pendingSourceRemoval else { return }
        pendingSourceRemoval = nil
        guard let session = appSession.activeLibraryBinding.activeSession,
              session.context.mode == .referenced else { return }
        let libraryID = session.context.id
        Task {
            do {
                try await session.runLibraryOperation {
                    try await session.removeReferencedSource(source.id)
                }
                guard appSession.activeLibraryBinding.context?.id == libraryID else { return }
                await reload()
            } catch {
                guard appSession.activeLibraryBinding.context?.id == libraryID else { return }
                errorMessage = "来源没有移除：\(error.localizedDescription)"
            }
        }
    }

    private var isFullScanRunning: Bool {
        !sources.isEmpty && sources.contains { sourceScanStates[$0.id] == .scanning }
    }

    private func refreshSources(sourceID: UUID? = nil) {
        guard let session = appSession.activeLibraryBinding.activeSession,
              session.context.mode == .referenced else { return }
        let libraryID = session.context.id
        Task {
            do {
                if let sourceID {
                    _ = try await appSession.refreshReferencedSource(
                        id: sourceID,
                        libraryID: libraryID
                    )
                } else {
                    try await appSession.refreshAllReferencedSources(libraryID: libraryID)
                }
                guard appSession.activeLibraryBinding.context?.id == libraryID else { return }
                await reload()
            } catch {
                guard appSession.activeLibraryBinding.context?.id == libraryID else { return }
                errorMessage = "无法重新扫描来源。"
            }
        }
    }

    private func sourceStatus(_ status: ReferencedSourceStatus) -> String {
        switch status {
        case .available: return "可用"
        case .stale: return "需要授权"
        case .permissionDenied: return "权限失效"
        case .offline: return "来源不可用"
        }
    }

    private func sourceRowStatus(_ source: ReferencedSourceDescriptor) -> String {
        sourceScanStates[source.id] == .failed ? "扫描失败" : sourceStatus(source.status)
    }
}

// Production fixture previews are defined in MusicSettingsContent.swift.
