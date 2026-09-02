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
    @State private var trackDeletionRequest: TrackDeletionConfirmationRequest?
    @State private var deletingTrackIDs: Set<UUID> = []

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
                    Text(storageModeDisplayTitle)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(storageModeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
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
        .trackDeletionConfirmation(item: $trackDeletionRequest) { tracks in
            deleteUnavailableTracks(tracks)
        }
    }

    private var storageModeDisplayTitle: String {
        activeMode?.dialogDisplayTitle ?? "未打开资料库"
    }

    private var storageModeDescription: String {
        switch activeMode {
        case .managed:
            return "音乐复制到资料库"
        case .referenced:
            return "音乐留在原位置，资料库保存索引"
        case nil:
            return "打开或新建资料库后可选择"
        }
    }

    private var librarySection: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SettingsSectionTitle("资料库")
                    Spacer()
                    Menu {
                        Button("新建资料库…") { flow.present(.setup(.referenced)) }
                        Button("打开资料库…") { openLibraryPanel() }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("添加资料库")
                    .accessibilityLabel("添加资料库")
                    .disabled(isWorking || isAddingMusic)
                }
                if registry.libraries.isEmpty {
                    settingsEmptyState("还没有资料库", systemImage: "externaldrive")
                } else {
                    ForEach(registry.libraries) { library in
                        libraryRow(library)
                    }
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
        MusicLibrarySettingsRow(
            name: library.displayName,
            path: library.lastKnownPath,
            mode: library.modeProjection,
            isActive: library.id == activeContext?.id,
            onOpen: { open(library) },
            onReveal: { revealLibrary(library) },
            onRemove: { pendingLibraryRemoval = library }
        )
        .disabled(isWorking || isAddingMusic)
        .opacity(isWorking || isAddingMusic ? 0.72 : 1)
    }

    private func settingsEmptyState(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var sourceSection: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SettingsSectionTitle("音乐来源")
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
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("完整扫描全部来源")
                    .accessibilityLabel("完整扫描全部来源")
                    .disabled(isWorking || isAddingMusic || sources.isEmpty || isFullScanRunning)
                    Button {
                        addMusicPanel()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("添加音乐")
                    .accessibilityLabel("添加音乐")
                    .disabled(isWorking || isAddingMusic)
                }

                if sources.isEmpty {
                    settingsEmptyState("尚未添加来源", systemImage: "folder")
                } else {
                    ForEach(visibleSources) { source in
                        MusicSourceSettingsRow(
                            name: source.displayName,
                            path: source.lastKnownPath,
                            mode: source.mode,
                            status: source.status,
                            isScanning: sourceScanStates[source.id] == .scanning,
                            scanFailed: sourceScanStates[source.id] == .failed,
                            onRescan: { refreshSources(sourceID: source.id) },
                            onReconnect: {
                                guard let libraryID = activeContext?.id else { return }
                                flow.present(.sourceReconnect(
                                    libraryID: libraryID,
                                    sourceIDs: [source.id]
                                ))
                            },
                            onRemove: { pendingSourceRemoval = source }
                        )
                        .id(source.id)
                        .disabled(isWorking || isAddingMusic)
                        .opacity(isWorking || isAddingMusic ? 0.72 : 1)
                    }
                }

                if sources.count > Self.collapsedSourceCount {
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
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var libraryDiagnosticsSection: some View {
        let summary = libraryVM.diagnostics.summary
        return SettingsSection("资料库概览") {
            libraryOverviewContent(summary)
        }
    }

    private func libraryOverviewContent(_ summary: LibraryQualitySummary) -> some View {
        let anomalyCount = summary.missingTracks
            + summary.offlineTracks
            + summary.permissionDeniedTracks
            + summary.staleTracks
            + summary.checkingTracks
        let metrics: [(String, String, Color)] = [
            ("歌曲", "\(summary.totalTracks)", themeStore.accentColor),
            ("可播放", "\(summary.playableTracks)", .green),
            ("总时长", formattedDuration(summary.totalDuration), .secondary),
            ("来源", activeMode == .referenced ? "\(logicalSourceCount)" : "—", .secondary),
            ("异常", "\(anomalyCount)", anomalyCount == 0 ? .secondary : .orange)
        ]

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: activeMode == .referenced ? "folder.fill" : "externaldrive.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(themeStore.accentColor)
                    .frame(width: 34, height: 34)
                    .background(themeStore.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(activeContext?.rootURL.lastPathComponent ?? "未打开资料库")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(activeContext?.rootURL.path ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let activeMode {
                        Text(activeMode == .referenced ? "原位" : "收集")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.055), in: Capsule(style: .continuous))
                }
            }

            Divider()

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 64), spacing: 8), count: 5),
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                    diagnosticMetric(metric.0, value: metric.1, color: metric.2)
                }
            }

            if !summary.topFormats.isEmpty {
                audioFormatBreakdown(summary)
            }

            if !libraryVM.diagnostics.duplicateGroups.isEmpty {
                Button {
                    isDuplicateReviewPresented = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.orange)
                        Text("重复歌曲")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    private func diagnosticMetric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 60 { return "\(totalMinutes)分钟" }
        return "\(totalMinutes / 60)小时 \(totalMinutes % 60)分"
    }

    private func audioFormatBreakdown(_ summary: LibraryQualitySummary) -> some View {
        let entries = Array(summary.topFormats.prefix(6))
        let total = max(summary.totalTracks, 1)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, item in
                        let ratio = CGFloat(item.count) / CGFloat(total)
                        Rectangle()
                            .fill(audioFormatColor(index))
                            .frame(width: max(3, proxy.size.width * ratio))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule(style: .continuous))
            }
            .frame(height: 10)

            HStack(spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, item in
                    Text("\(item.format) \(item.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            audioFormatColor(index).opacity(0.12),
                            in: Capsule(style: .continuous)
                        )
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func audioFormatColor(_ index: Int) -> Color {
        [
            themeStore.accentColor,
            .blue,
            .purple,
            .orange,
            .green,
            .pink
        ][index % 6]
    }

    private var logicalSourceCount: Int {
        let directoryCount = sources.reduce(into: 0) { count, source in
            if source.mode == .directory { count += 1 }
        }
        let hasIndividualSources = sources.contains { $0.mode == .file }
        return directoryCount + (hasIndividualSources ? 1 : 0)
    }

    private var deletePolicySection: some View {
        SettingsSection("偏好设置") {
            HStack(spacing: 12) {
                Text("删除歌曲")
                    .font(.callout)
                Spacer(minLength: 8)
                AppDialogCapsuleSlider(
                    segments: ReferencedTrackDeletePolicy.allCases,
                    selection: deletePolicyBinding,
                    label: { $0.dialogDisplayTitle }
                )
            }
        }
    }

    private var deletePolicyBinding: Binding<ReferencedTrackDeletePolicy> {
        Binding(
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
        )
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
                    Text(unavailableTracks.isEmpty
                         ? "没有失效歌曲"
                         : "\(unavailableTracks.count) 首歌曲暂时不可用")
                        .font(.callout)

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                if !unavailableTracks.isEmpty {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleUnavailableTracks) { track in
                            unavailableTrackRow(track)
                        }
                    }

                    if unavailableTracks.count > Self.collapsedSourceCount {
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
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private func unavailableTrackRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityLabel("失效")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(track.title.isEmpty ? "未命名歌曲" : track.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
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

            Button {
                trackDeletionRequest = TrackDeletionConfirmationRequest(tracks: [track])
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(0.11), in: Circle())
            }
            .buttonStyle(.plain)
            .help("从资料库删除")
            .accessibilityLabel("从资料库删除")
            .disabled(deletingTrackIDs.contains(track.id))
        }
        .id(track.id)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
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

    private func deleteUnavailableTracks(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let ids = Set(tracks.map(\.id))
        deletingTrackIDs.formUnion(ids)
        Task { @MainActor in
            await libraryVM.deleteTracks(tracks)
            deletingTrackIDs.subtract(ids)
            await reload()
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
                        actionTitle: "查看失败"
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

}

// Production fixture previews are defined in MusicSettingsContent.swift.
