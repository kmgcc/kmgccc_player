import AppKit
import SwiftUI

struct LibrarySetupFlow: View {
    @Bindable var flow: LibrarySetupViewModel
    let registry: MusicLibraryRegistry
    let onChange: @MainActor () async -> Void
    /// Called after the user explicitly dismisses the flow (取消/关闭) so a
    /// hosting window can close deterministically instead of relying on view
    /// diffing of the presentation state.
    var onRequestClose: () -> Void = {}

    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isPlaylistCreationPromptPresented = false
    @State private var shouldPresentPlaylistSourceSelectionAfterPromptDismiss = false
    @State private var isPlaylistSourceSelectionPresented = false

    @ViewBuilder
    var body: some View {
        Group {
            switch flow.presentation {
            case let .reconnectRequired(libraryID, mode):
                LibraryReconnectView(
                    flow: flow,
                    target: .libraryRoot(libraryID: libraryID, mode: mode),
                    onChange: onChange,
                    onRequestClose: onRequestClose
                )
                .id("library-\(libraryID.uuidString)")
            case let .sourceReconnect(libraryID, sourceIDs):
                LibraryReconnectView(
                    flow: flow,
                    target: .sources(libraryID: libraryID, sourceIDs: sourceIDs),
                    onChange: onChange,
                    onRequestClose: onRequestClose
                )
                .id("sources-\(libraryID.uuidString)-\(sourceIDs.map(\.uuidString).joined())")
            case .none:
                EmptyView()
            default:
                setupDialog
            }
        }
        .sheet(isPresented: $isPlaylistSourceSelectionPresented) {
            let entries = LibraryImportSourceEntry.makeEntries(from: flow.selectedMusicURLs)
            LibraryImportSourceSelectionSheet(
                entries: entries,
                initiallySelectedIDs: flow.playlistSourceEntries.isEmpty
                    ? Set(entries.map(\.id))
                    : Set(flow.playlistSourceEntries.map(\.id))
            ) { entries in
                flow.setPlaylistSourceEntries(entries)
                flow.step = .location
            }
        }
        .sheet(
            isPresented: $isPlaylistCreationPromptPresented,
            onDismiss: {
                guard shouldPresentPlaylistSourceSelectionAfterPromptDismiss else { return }
                shouldPresentPlaylistSourceSelectionAfterPromptDismiss = false
                isPlaylistSourceSelectionPresented = true
            }
        ) {
            LibraryPlaylistCreationPrompt(
                onCreate: {
                    shouldPresentPlaylistSourceSelectionAfterPromptDismiss = true
                    isPlaylistCreationPromptPresented = false
                },
                onSkip: {
                    flow.clearPlaylistSourceEntries()
                    flow.step = .location
                    isPlaylistCreationPromptPresented = false
                }
            )
        }
    }

    private func presentPlaylistSourceSelectionIfNeeded() {
        guard !flow.selectedMusicURLs.isEmpty else {
            flow.clearPlaylistSourceEntries()
            flow.step = .location
            return
        }
        isPlaylistCreationPromptPresented = true
    }

    private var setupDialog: some View {
        SettingsTaskDialog(
            title: title,
            subtitle: subtitle,
            systemImage: icon,
            iconColor: themeStore.accentColor
        ) {
            content.frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        } footer: {
            HStack {
                if canGoBack { SettingsTaskDialogButton("返回", kind: .secondary) { goBack() } }
                Spacer()
                footerButtons
            }
        }
        .frame(minWidth: 460, idealWidth: 500, maxWidth: 560)
        // The panel is allowed to close while a lifecycle operation is in
        // flight.  The operation is owned by AppSessionHost and will either
        // finish or be quiesced by the session coordinator.
        .interactiveDismissDisabled(false)
    }

    private var title: String {
        switch flow.presentation {
        case .chooser: return "选择资料库"
        case .reconnectRequired: return "找不到资料库"
        case .sourceReconnect: return "重新连接来源"
        default:
            switch flow.step {
            case .storage: return "存储方式"
            case .music: return "选择音乐"
            case .location: return "选择位置"
            }
        }
    }

    private var subtitle: String {
        switch flow.presentation {
        case .chooser: return "选择要打开的资料库"
        case .reconnectRequired: return "选择资料库的新位置"
        case .sourceReconnect: return "选择外部音乐的新位置"
        default:
            switch flow.step {
            case .storage: return flow.mode == .managed ? "音乐会复制到资料库" : "音乐保留在原位置"
            case .music: return "可稍后添加"
            case .location: return "选择资料库的存储位置"
            }
        }
    }

    private var icon: String {
        switch flow.presentation {
        case .reconnectRequired: return "externaldrive.badge.exclamationmark"
        case .sourceReconnect: return "folder.badge.questionmark"
        case .chooser: return "music.note.list"
        default: return "externaldrive.fill.badge.plus"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.presentation {
        case .chooser(let mode):
            LibraryChooserView(
                libraries: registry.libraries.filter { $0.modeProjection == mode },
                onOpen: open
            )
        case .reconnectRequired:
            ContentUnavailableView("找不到资料库", systemImage: "externaldrive.badge.exclamationmark", description: Text("请使用“打开资料库”选择当前位置。"))
        case .sourceReconnect:
            EmptyView()
        case .setup:
            setupContent
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var setupContent: some View {
        switch flow.step {
        case .storage:
            AppDialogCapsuleSlider(
                segments: MusicLibraryMode.allCases,
                selection: $flow.mode
            ) { mode in
                mode.dialogDisplayTitle
            }
        case .music:
            musicStepContent
        case .location:
            VStack(alignment: .leading, spacing: 12) {
                if let existing = flow.existingLibraryContext {
                    Label(
                        "所选位置已有\(existing.mode == .managed ? "复制到资料库" : "保留原位置")资料库",
                        systemImage: "externaldrive.fill"
                    )
                    Text(existing.rootURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("可以直接打开它；如需新建资料库，请返回并选择一个没有资料库的位置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: "character.cursor.ibeam")
                            .foregroundStyle(themeStore.accentColor)
                            .frame(width: 18)
                        TextField("资料库名称", text: $flow.displayName)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    storageDirectorySection
                    if case .failed(let message) = flow.operation {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    if flow.operation == .working {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在创建") }
                    }
                }
            }
        }
    }

    /// Step 2: incremental list of music sources. Re-opening the picker
    /// appends to the list; each row can be removed individually.
    private var musicStepContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    chooseMusic()
                } label: {
                    Label("添加文件或文件夹", systemImage: "plus")
                }
                .buttonStyle(AppDialogGlassButtonStyle(kind: .secondary))
                Spacer()
                if !flow.selectedMusicURLs.isEmpty {
                    Text("已选择 \(flow.selectedMusicURLs.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !flow.selectedMusicURLs.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(flow.selectedMusicURLs.enumerated()), id: \.element) { index, url in
                            HStack(spacing: 10) {
                                Image(systemName: url.hasDirectoryPath ? "folder.fill" : "music.note")
                                    .foregroundStyle(themeStore.accentColor)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    flow.removeMusicURL(url)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("移除")
                                .accessibilityLabel("移除 \(url.lastPathComponent)")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .padding(.bottom, index < flow.selectedMusicURLs.count - 1 ? 6 : 0)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    /// Step 3: required storage directory choice. The default directory is
    /// only the initial browsing location; it is not treated as selected.
    private var storageDirectorySection: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(themeStore.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(flow.storageParentURL == nil ? "未选择" : "存储位置")
                    .font(.callout.weight(.medium))
                if let parent = flow.storageParentURL {
                    Text(parent.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(flow.storageParentURL == nil ? "选择位置" : "更改") {
                chooseStorageLocation()
            }
            .buttonStyle(AppDialogGlassButtonStyle(kind: .secondary))
            .disabled(flow.operation == .working)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch flow.presentation {
        case .reconnectRequired:
            SettingsTaskDialogButton("关闭", kind: .secondary) { dismissFlow() }
        case .sourceReconnect:
            EmptyView()
        case .chooser:
            SettingsTaskDialogButton("取消", kind: .secondary) { dismissFlow() }
        case .setup:
            switch flow.step {
            case .storage:
                SettingsTaskDialogButton("取消", kind: .secondary) { dismissFlow() }
                SettingsTaskDialogButton("下一步", kind: .primary) { flow.step = .music }
            case .music:
                SettingsTaskDialogButton("稍后添加", kind: .secondary) {
                    flow.clearPlaylistSourceEntries()
                    flow.selectedMusicURLs = []
                    flow.step = .location
                }
                SettingsTaskDialogButton("下一步", kind: .primary) { presentPlaylistSourceSelectionIfNeeded() }
            case .location:
                if let existing = flow.existingLibraryContext {
                    SettingsTaskDialogButton("重新选择位置", kind: .secondary) {
                        flow.returnFromExistingLibrary()
                    }
                    SettingsTaskDialogButton("打开", kind: .primary) { openExisting(existing) }
                } else {
                    SettingsTaskDialogButton(
                        "创建资料库",
                        kind: .primary,
                        disabled: flow.operation == .working
                            || !flow.isStorageLocationExplicitlyChosen
                            || flow.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) { createLibrary() }
                }
            }
        case .none:
            EmptyView()
        }
    }

    private var canGoBack: Bool {
        if case .setup = flow.presentation {
            guard flow.operation != .working else { return false }
            return flow.step != .storage
        }
        return false
    }

    private func goBack() {
        switch flow.step {
        case .music: flow.step = .storage
        case .location: flow.step = .music
        case .storage: break
        }
    }

    private func dismissFlow() {
        flow.dismiss()
        onRequestClose()
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = FileImportService.supportedUTTypes
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "添加"
        if let wizardPanel = LibrarySetupPanelPresenter.sheetAnchorPanel {
            // Attached as a sheet: closing the picker returns focus to the
            // wizard panel instead of the main window.
            panel.beginSheetModal(for: wizardPanel) { result in
                if result == .OK { flow.addMusicURLs(panel.urls) }
            }
        } else {
            panel.begin { result in
                if result == .OK { flow.addMusicURLs(panel.urls) }
                DispatchQueue.main.async { LibrarySetupPanelPresenter.bringToFront() }
            }
        }
    }

    private func chooseStorageLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择资料库的存储目录"
        panel.directoryURL = flow.effectiveStorageParentURL
        if let wizardPanel = LibrarySetupPanelPresenter.sheetAnchorPanel {
            panel.beginSheetModal(for: wizardPanel) { result in
                guard result == .OK, let parent = panel.url else { return }
                flow.storageParentURL = parent
            }
        } else {
            panel.begin { result in
                guard result == .OK, let parent = panel.url else { return }
                flow.storageParentURL = parent
                DispatchQueue.main.async { LibrarySetupPanelPresenter.bringToFront() }
            }
        }
    }

    private func createLibrary() {
        guard let parent = flow.storageParentURL else {
            flow.fail("请先选择资料库存储位置。")
            return
        }
        let parentAccess = LibraryInitialImportSelection(urls: [parent])
        let operation = flow.beginOperation()
        let mode = flow.mode
        let displayName = flow.displayName
        let initialImportSelection = flow.initialImportSelection
        let task = Task { @MainActor in
            defer { parentAccess.release() }
            do {
                let result = try await appSession.createMusicLibrary(
                    mode: mode,
                    parentURL: parent,
                    displayName: displayName,
                    initialImportSelection: initialImportSelection,
                    initialImportPolicy: .background
                )
                guard flow.isCurrentOperation(operation) else { return }
                switch result {
                case .created(_, _):
                    flow.completeAndDismiss()
                    await onChange()
                case .existingLibrary(let context):
                    flow.showExistingLibrary(context, requestedMode: flow.mode)
                case .existingLibraryModeMismatch(let context, let requestedMode):
                    flow.showExistingLibrary(context, requestedMode: requestedMode)
                }
            } catch {
                guard flow.isCurrentOperation(operation) else { return }
                flow.fail(creationFailureMessage(error, parent: parent))
            }
        }
        flow.setOperationCancellation { task.cancel() }
    }

    private func creationFailureMessage(_ error: Error, parent: URL) -> String {
        let destination = parent
            .appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true)
            .standardizedFileURL
            .path
        if let creationError = error as? LibraryCreationError {
            switch creationError {
            case .destinationContainsUnknownItems:
                return "该位置已有其他内容：\(destination)。请选择另一个存储目录，或清理后重试。"
            case .invalidDisplayName:
                return "资料库名称不能为空。"
            default:
                break
            }
        }
        return "创建资料库失败，请检查存储目录权限后重试。"
    }

    private func openExisting(_ context: LibraryContext) {
        // The library is already open — treat "打开" as success instead of
        // re-running the whole open transaction against the active session.
        if appSession.activeLibraryBinding.context?.id == context.id {
            flow.completeAndDismiss()
            return
        }
        let operation = flow.beginOperation()
        Task {
            do {
                let sourceIDs = try await appSession.openInspectedMusicLibrary(context)
                guard flow.isCurrentOperation(operation) else { return }
                if sourceIDs.isEmpty {
                    flow.completeAndDismiss()
                } else {
                    flow.present(.sourceReconnect(libraryID: context.id, sourceIDs: sourceIDs))
                }
                await onChange()
            } catch {
                guard flow.isCurrentOperation(operation) else { return }
                flow.fail("无法打开资料库。")
            }
        }
    }

    private func open(_ library: MusicLibraryBookmark) {
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
                await onChange()
            } catch RegisteredLibraryActivationError.reconnectRequired {
                guard flow.isCurrentOperation(operation) else { return }
                flow.present(.reconnectRequired(libraryID: library.id, mode: library.modeProjection))
            } catch {
                guard flow.isCurrentOperation(operation) else { return }
                flow.fail("无法打开资料库。")
            }
        }
    }
}

/// Small custom confirmation used between the music and storage steps.  A
/// native alert here made the wizard switch visual languages; this keeps the
/// same glass header/footer and button treatment as the rest of the flow.
private struct LibraryPlaylistCreationPrompt: View {
    let onCreate: () -> Void
    let onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        AppDialogFrame(
            header: {
                AppDialogHeader(
                    title: "创建播放列表？",
                    subtitle: "从已选音乐中选择要同步的来源",
                    systemImage: "music.note.list",
                    iconColor: themeStore.accentColor
                )
                .padding(.horizontal, AppDialogTokens.headerHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 12)
            },
            content: {
                Text("文件夹来源会持续同步；单独歌曲只加入这次创建的播放列表。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            },
            footer: {
                AppDialogFooter {
                    HStack {
                        Spacer()
                        Button("取消") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .buttonStyle(AppDialogGlassButtonStyle(kind: .secondary))
                        Button("暂不新建") {
                            onSkip()
                            dismiss()
                        }
                        .buttonStyle(AppDialogGlassButtonStyle(kind: .secondary))
                        Button("创建播放列表") {
                            onCreate()
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(
                            AppDialogGlassButtonStyle(kind: .primary, tint: themeStore.accentColor)
                        )
                    }
                }
            }
        )
        .frame(width: 460)
    }
}

/// Compact source selection shared by library creation and Settings source
/// import. It keeps all individual files as one selectable row and lets folder
/// rows opt into the persisted source-to-playlist binding.
struct LibraryImportSourceSelectionSheet: View {
    let entries: [LibraryImportSourceEntry]
    let onConfirm: ([LibraryImportSourceEntry]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var selectedEntryIDs: Set<String>

    init(
        entries: [LibraryImportSourceEntry],
        initiallySelectedIDs: Set<String> = [],
        onConfirm: @escaping ([LibraryImportSourceEntry]) -> Void
    ) {
        self.entries = entries
        self.onConfirm = onConfirm
        _selectedEntryIDs = State(initialValue: initiallySelectedIDs)
    }

    var body: some View {
        AppDialogFrame(
            header: {
                AppDialogHeader(
                    title: "选择播放列表来源",
                    subtitle: "选择要同步的来源",
                    systemImage: "music.note.list",
                    iconColor: themeStore.accentColor
                )
                .padding(.horizontal, AppDialogTokens.headerHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 12)
            },
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(entries) { entry in
                                let isSelected = selectedEntryIDs.contains(entry.id)
                                Button {
                                    if isSelected {
                                        selectedEntryIDs.remove(entry.id)
                                    } else {
                                        selectedEntryIDs.insert(entry.id)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isSelected ? themeStore.accentColor : .secondary)
                                            .font(.system(size: 16, weight: .medium))
                                        Image(systemName: entry.kind == .directory ? "folder.fill" : "music.note.list")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.displayName)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text(entry.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            .truncationMode(.middle)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected
                                        ? themeStore.accentColor.opacity(0.10)
                                        : Color.primary.opacity(0.045),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                    .padding(.leading, 4)

                    Text("文件夹来源会随扫描更新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            },
            footer: {
                AppDialogFooter {
                    HStack {
                        Spacer()
                        Button("取消") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .buttonStyle(AppDialogGlassButtonStyle(kind: .secondary))
                        Button("继续") {
                            let selected = entries.filter { selectedEntryIDs.contains($0.id) }
                            onConfirm(selected)
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(
                            AppDialogGlassButtonStyle(kind: .primary, tint: themeStore.accentColor)
                        )
                    }
                }
            }
        )
        .frame(width: 460)
    }
}
