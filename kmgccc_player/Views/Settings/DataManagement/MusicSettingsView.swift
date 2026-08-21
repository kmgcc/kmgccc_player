import AppKit
import SwiftUI

struct MusicSettingsView: View {
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(LibraryViewModel.self) private var libraryVM

    @State private var registry = MusicLibraryRegistry()
    @State private var sources: [ReferencedSourceDescriptor] = []
    @State private var settings = LibraryScopedSettings()
    @State private var sourceScanStates: [UUID: ReferencedSourceScanState] = [:]
    @State private var errorMessage: String?
    @State private var pendingLibraryRemoval: MusicLibraryBookmark?
    @State private var pendingSourceRemoval: ReferencedSourceDescriptor?
    @State private var isAddingMusic = false
    @State private var pendingImportURLs: [URL] = []
    @State private var isImportSourceSelectionPresented = false
    @State private var isSourceListExpanded = false
    @State private var isMissingListExpanded = false
    @State private var isMissingCleanupConfirmPresented = false

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
                    Picker("音乐存储方式", selection: modeBinding) {
                        Text("复制到资料库").tag(MusicLibraryMode.managed)
                        Text("保留原位置").tag(MusicLibraryMode.referenced)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isWorking || isAddingMusic || activeMode == nil)
                    .accessibilityValue(activeMode == .referenced ? "保留原位置" : "复制到资料库")

                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            librarySection

            if activeMode == .referenced {
                sourceSection
                deletePolicySection
                missingTracksSection
            }
        }
        .task(id: appSession.activeLibraryBinding.generation) {
            await reload()
            while !Task.isCancelled {
                sourceScanStates = await appSession.referencedSourceScanStates()
                try? await Task.sleep(for: .milliseconds(250))
            }
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
        .confirmationDialog(
            "清空失效歌曲？",
            isPresented: $isMissingCleanupConfirmPresented
        ) {
            Button("删除 \(unavailableTracks.count) 首失效歌曲", role: .destructive) { cleanupMissingTracks() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从资料库删除这些歌曲的元数据；磁盘上的文件不受影响。若来源只是暂时离线，重连后可恢复的歌曲也会被一并删除。")
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var modeBinding: Binding<MusicLibraryMode> {
        Binding(
            get: { activeMode ?? .managed },
            set: { requested in route(to: requested) }
        )
    }

    private var librarySection: some View {
        SettingsSection("资料库") {
            VStack(spacing: 0) {
                HStack {
                    Text("已添加资料库").font(.callout.weight(.medium))
                    Spacer()
                    Menu {
                        Button("新建资料库…") { flow.present(.setup(activeMode ?? .managed)) }
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

    private func libraryRow(_ library: MusicLibraryBookmark) -> some View {
        HStack(spacing: 10) {
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

            Menu {
                Button("更改位置…") { relocatePanel(library) }
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: library.lastKnownPath)]) }
                Button("重新扫描") { Task { await libraryVM.reloadLibrary() } }
                    .disabled(library.id != activeContext?.id)
                Divider()
                Button("移到废纸篓…", role: .destructive) { pendingLibraryRemoval = library }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("资料库操作")
        }
        .contentShape(Rectangle())
        .onTapGesture { open(library) }
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
                            Button("重新扫描") { refreshSources() }
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

    private var deletePolicySection: some View {
        SettingsSection("删除歌曲时") {
            Picker("删除歌曲时", selection: Binding(
                get: { settings.referencedTrackDeletePolicy },
                set: { policy in
                    settings.referencedTrackDeletePolicy = policy
                    Task {
                        do { try await appSession.setReferencedTrackDeletePolicy(policy) }
                        catch { errorMessage = "无法保存删除方式。" }
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
                        Text("失效歌曲在列表中显示为灰色。清空只删元数据，不动磁盘文件；临时离线请先重连来源。")
                            .settingsDescriptionStyle()
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Button("一键清空失效歌曲…") { isMissingCleanupConfirmPresented = true }
                        .disabled(unavailableTracks.isEmpty || isWorking)
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

    private func cleanupMissingTracks() {
        let staleTracks = unavailableTracks
        guard !staleTracks.isEmpty else { return }
        Task {
            await libraryVM.deleteTracks(staleTracks)
        }
    }

    private func reload() async {
        registry = await appSession.musicLibraryRegistrySnapshot()
        do {
            sources = try await appSession.referencedSources()
            settings = try await appSession.libraryScopedSettings()
        } catch {
            errorMessage = "无法读取资料库设置。"
        }
    }

    private func route(to mode: MusicLibraryMode) {
        let target = flow.routeModeSelection(
            mode,
            activeMode: activeMode,
            registry: registry
        )
        if let id = target, let library = registry.library(id: id) { open(library) }
    }

    private func open(_ library: MusicLibraryBookmark) {
        guard library.id != activeContext?.id else { return }
        flow.beginOperation()
        Task {
            do {
                let sourceIDs = try await appSession.activateRegisteredLibrary(id: library.id)
                if sourceIDs.isEmpty {
                    flow.completeAndDismiss()
                } else {
                    flow.present(.sourceReconnect(libraryID: library.id, sourceIDs: sourceIDs))
                }
                await reload()
            } catch RegisteredLibraryActivationError.reconnectRequired {
                flow.present(.reconnectRequired(libraryID: library.id, mode: library.modeProjection))
            } catch LibrarySwitchBlockedError.enrichmentInProgress {
                flow.finishOperation()
            } catch {
                flow.fail("无法打开资料库。")
                errorMessage = "无法打开资料库。"
            }
        }
    }

    private func openLibraryPanel() {
        chooseDirectory(prompt: "打开") { url, access in
            flow.beginOperation()
            Task {
                defer { access.release() }
                do {
                    let sourceIDs = try await appSession.openMusicLibrary(at: url)
                    if let libraryID = appSession.activeLibraryBinding.context?.id,
                       !sourceIDs.isEmpty {
                        flow.present(.sourceReconnect(libraryID: libraryID, sourceIDs: sourceIDs))
                    } else {
                        flow.completeAndDismiss()
                    }
                    await reload()
                }
                catch LibrarySwitchBlockedError.enrichmentInProgress { flow.finishOperation() }
                catch { flow.fail("无法打开资料库。"); errorMessage = "所选位置不是可用资料库。" }
            }
        }
    }

    private func relocatePanel(_ library: MusicLibraryBookmark) {
        chooseDirectory(prompt: "移动") { parent, access in
            flow.beginOperation()
            Task {
                defer { access.release() }
                do { try await appSession.relocateMusicLibrary(id: library.id, to: parent); flow.completeAndDismiss(); await reload() }
                catch { flow.fail("无法移动资料库。"); errorMessage = "资料库位置没有更改。" }
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
        Task {
            defer {
                selection.release()
                isAddingMusic = false
            }
            do {
                let result = try await appSession.importMusicSelection(selection)
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
                errorMessage = "未能添加所选音乐。"
                await reload()
            }
        }
    }

    private func removePendingLibrary() {
        guard let library = pendingLibraryRemoval else { return }
        pendingLibraryRemoval = nil
        flow.beginOperation()
        Task {
            let latestRegistry = await appSession.musicLibraryRegistrySnapshot()
            guard let latest = latestRegistry.library(id: library.id),
                  latest.lastKnownPath == library.lastKnownPath,
                  latest.modeProjection == library.modeProjection else {
                flow.fail("资料库列表已变化，请重新加载后再操作。")
                errorMessage = "资料库列表已变化，未执行删除。"
                await reload()
                return
            }
            do {
                try await appSession.removeMusicLibrary(id: library.id)
                flow.completeAndDismiss()
                await reload()
            } catch {
                flow.fail("无法移到废纸篓。")
                errorMessage = "资料库没有删除。"
            }
        }
    }

    private func removePendingSource() {
        guard let source = pendingSourceRemoval else { return }
        pendingSourceRemoval = nil
        Task {
            do { try await appSession.removeReferencedSource(id: source.id); await reload() }
            catch { errorMessage = "来源没有移除。" }
        }
    }

    private func refreshSources() {
        Task {
            do { _ = try await appSession.activeLibraryBinding.activeSession?.refreshReferencedSources(); await reload() }
            catch { errorMessage = "无法重新扫描来源。" }
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
