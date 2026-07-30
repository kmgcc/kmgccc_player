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

    @ViewBuilder
    var body: some View {
        switch flow.presentation {
        case let .reconnectRequired(libraryID, mode):
            LibraryReconnectView(
                flow: flow,
                target: .libraryRoot(libraryID: libraryID, mode: mode),
                onChange: onChange
            )
            .id("library-\(libraryID.uuidString)")
        case let .sourceReconnect(libraryID, sourceIDs):
            LibraryReconnectView(
                flow: flow,
                target: .sources(libraryID: libraryID, sourceIDs: sourceIDs),
                onChange: onChange
            )
            .id("sources-\(libraryID.uuidString)-\(sourceIDs.map(\.uuidString).joined())")
        case .none:
            EmptyView()
        default:
            setupDialog
        }
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
        .frame(width: 500)
        .interactiveDismissDisabled(flow.operation == .working)
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
        case .chooser: return "选择要打开的资料库。"
        case .reconnectRequired: return "选择资料库的新位置。"
        case .sourceReconnect: return "选择外部音乐的新位置。"
        default:
            switch flow.step {
            case .storage: return flow.mode == .managed ? "音乐将复制到资料库。" : "音乐将保留在原位置。"
            case .music: return "可多次添加文件或文件夹，也可稍后添加。"
            case .location: return "选择资料库的存储目录，或直接使用默认目录。"
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
            Picker("音乐存储方式", selection: $flow.mode) {
                Text("复制到资料库").tag(MusicLibraryMode.managed)
                Text("保留原位置").tag(MusicLibraryMode.referenced)
            }
            .pickerStyle(.segmented)
        case .music:
            musicStepContent
        case .location:
            VStack(alignment: .leading, spacing: 12) {
                if flow.createdLibraryAwaitingImport != nil {
                    Label(
                        "“\(flow.displayName)”已创建，音乐尚未导入",
                        systemImage: "music.note.list"
                    )
                    if case .failed(let message) = flow.operation {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    if flow.operation == .working {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在导入")
                        }
                    }
                } else if let existing = flow.existingLibraryContext {
                    Label(
                        "此位置已有\(existing.mode == .managed ? "复制到资料库" : "保留原位置")资料库",
                        systemImage: "externaldrive.fill"
                    )
                    Text("可以直接打开它；或忽略它，在同一位置新建另一个资料库（会自动使用新的子目录）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("资料库名称", text: $flow.displayName)
                        .textFieldStyle(.roundedBorder)
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
                Button("添加文件或文件夹…") { chooseMusic() }
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
                            // Trailing padding keeps the remove button clear
                            // of the overlay scrollbar.
                            .padding(.vertical, 6)
                            .padding(.trailing, 14)
                            if index < flow.selectedMusicURLs.count - 1 {
                                Divider().opacity(0.25)
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    /// Step 3: required storage directory choice. The default is derived from
    /// the music sources; the user may override it explicitly.
    private var storageDirectorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("存储目录")
                .font(.callout.weight(.medium))
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(themeStore.accentColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(flow.storageParentURL == nil ? "默认目录" : "自定目录")
                        .font(.callout)
                    Text(flow.effectiveStorageParentURL
                        .appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true)
                        .path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("选择位置…") { chooseStorageLocation() }
                    .disabled(flow.operation == .working)
            }
            Text("资料库目录包含索引、元数据以及缓存，将在其中创建“\(LibraryPaths.rootDirectoryName)”文件夹。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch flow.presentation {
        case .reconnectRequired:
            SettingsTaskDialogButton("关闭", kind: .secondary) { dismissFlow() }
            SettingsTaskDialogButton("重新连接", kind: .primary, disabled: true) {}
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
                SettingsTaskDialogButton("稍后添加", kind: .secondary) { flow.selectedMusicURLs = []; flow.step = .location }
                SettingsTaskDialogButton("下一步", kind: .primary) { flow.step = .location }
            case .location:
                if flow.createdLibraryAwaitingImport != nil {
                    SettingsTaskDialogButton(
                        "重试导入",
                        kind: .primary,
                        disabled: flow.operation == .working || flow.initialImportSelection == nil
                    ) { retryInitialImport() }
                } else if let existing = flow.existingLibraryContext {
                    // Ignore the library already at this location and create
                    // a new numbered sibling folder in the same parent.
                    SettingsTaskDialogButton("不打开，继续新建", kind: .secondary) {
                        createLibrary(ignoreExistingAtLocation: true)
                    }
                    SettingsTaskDialogButton("打开", kind: .primary) { openExisting(existing) }
                } else {
                    SettingsTaskDialogButton(
                        "创建资料库",
                        kind: .primary,
                        disabled: flow.operation == .working || flow.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            if flow.createdLibraryAwaitingImport != nil {
                return flow.step == .location
            }
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

    private func createLibrary(ignoreExistingAtLocation: Bool = false) {
        let parent = flow.effectiveStorageParentURL
        let parentAccess = LibraryInitialImportSelection(urls: [parent])
        flow.beginOperation()
        Task {
            defer { parentAccess.release() }
            do {
                let result = try await appSession.createMusicLibrary(
                    mode: flow.mode,
                    parentURL: parent,
                    displayName: flow.displayName,
                    initialImportSelection: flow.initialImportSelection,
                    allowAlternateDestinationWhenOccupied: ignoreExistingAtLocation
                )
                switch result {
                case .created(_, let initialImport):
                    if let initialImport, initialImport.isPartial {
                        appSession.uiState.showSidebarNotice(
                            "部分音乐未导入",
                            style: .warning,
                            actionTitle: "打开设置"
                        )
                    }
                    flow.completeAndDismiss()
                    await onChange()
                case .existingLibrary(let context):
                    flow.showExistingLibrary(context, requestedMode: flow.mode)
                case .existingLibraryModeMismatch(let context, let requestedMode):
                    flow.showExistingLibrary(context, requestedMode: requestedMode)
                }
            } catch LibraryInitialImportError.initialImportFailed {
                if let context = appSession.activeLibraryBinding.context {
                    flow.failInitialImport(
                        in: context,
                        message: "未能导入所选音乐，请返回重新选择后重试。"
                    )
                } else {
                    flow.fail("创建失败，请重试。")
                }
            } catch LibrarySwitchBlockedError.enrichmentInProgress {
                flow.fail("正在后台补全歌曲信息，完成后才能切换资料库。")
            } catch {
                flow.fail("创建失败，请重试。")
            }
        }
    }

    private func openExisting(_ context: LibraryContext) {
        // The library is already open — treat "打开" as success instead of
        // re-running the whole open transaction against the active session.
        if appSession.activeLibraryBinding.context?.id == context.id {
            flow.completeAndDismiss()
            return
        }
        flow.beginOperation()
        Task {
            do {
                let sourceIDs = try await appSession.openInspectedMusicLibrary(context)
                if sourceIDs.isEmpty {
                    flow.completeAndDismiss()
                } else {
                    flow.present(.sourceReconnect(libraryID: context.id, sourceIDs: sourceIDs))
                }
                await onChange()
            } catch LibrarySwitchBlockedError.enrichmentInProgress {
                flow.fail("正在后台补全歌曲信息，完成后才能切换资料库。")
            } catch {
                flow.fail("无法打开资料库。")
            }
        }
    }

    private func retryInitialImport() {
        guard let selection = flow.initialImportSelection,
              let expected = flow.createdLibraryAwaitingImport,
              appSession.activeLibraryBinding.context?.id == expected.id else {
            flow.fail("当前资料库已更改，请重新打开资料库。")
            return
        }
        flow.beginOperation()
        Task {
            do {
                let result = try await appSession.importMusicSelection(selection)
                if result.isPartial {
                    appSession.uiState.showSidebarNotice(
                        "部分音乐未导入",
                        style: .warning,
                        actionTitle: "打开设置"
                    )
                }
                flow.completeAndDismiss()
                await onChange()
            } catch {
                flow.failInitialImport(
                    in: expected,
                    message: "仍未能导入所选音乐，请返回重新选择后重试。"
                )
            }
        }
    }

    private func open(_ library: MusicLibraryBookmark) {
        flow.beginOperation()
        Task {
            do {
                let sourceIDs = try await appSession.activateRegisteredLibrary(id: library.id)
                if sourceIDs.isEmpty {
                    flow.completeAndDismiss()
                } else {
                    flow.present(.sourceReconnect(libraryID: library.id, sourceIDs: sourceIDs))
                }
                await onChange()
            } catch RegisteredLibraryActivationError.reconnectRequired {
                flow.present(.reconnectRequired(libraryID: library.id, mode: library.modeProjection))
            } catch LibrarySwitchBlockedError.enrichmentInProgress {
                flow.fail("正在后台补全歌曲信息，完成后才能切换资料库。")
            } catch {
                flow.fail("无法打开资料库。")
            }
        }
    }
}
