import AppKit
import SwiftUI

struct LibrarySetupFlow: View {
    @Bindable var flow: LibrarySetupViewModel
    let registry: MusicLibraryRegistry
    let onChange: @MainActor () async -> Void

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
            case .music: return "可选择文件或文件夹，也可稍后添加。"
            case .location: return "将在所选位置创建“kmgccc_player Library”文件夹。"
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
            VStack(alignment: .leading, spacing: 12) {
                Button("选择文件或文件夹") { chooseMusic() }
                if !flow.selectedMusicURLs.isEmpty {
                    Text("已选择 \(flow.selectedMusicURLs.count) 项").foregroundStyle(.secondary)
                }
            }
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
                } else {
                    TextField("资料库名称", text: $flow.displayName)
                        .textFieldStyle(.roundedBorder)
                    if case .failed(let message) = flow.operation {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    if flow.operation == .working {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在创建") }
                    }
                    Button("选择位置") { chooseLocationAndCreate() }.disabled(flow.operation == .working)
                }
            }
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch flow.presentation {
        case .reconnectRequired:
            SettingsTaskDialogButton("关闭", kind: .secondary) { flow.dismiss() }
            SettingsTaskDialogButton("重新连接", kind: .primary, disabled: true) {}
        case .sourceReconnect:
            EmptyView()
        case .chooser:
            SettingsTaskDialogButton("取消", kind: .secondary) { flow.dismiss() }
        case .setup:
            switch flow.step {
            case .storage:
                SettingsTaskDialogButton("取消", kind: .secondary) { flow.dismiss() }
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
                    SettingsTaskDialogButton("返回", kind: .secondary) { flow.returnFromExistingLibrary() }
                    SettingsTaskDialogButton("打开", kind: .primary) { openExisting(existing) }
                } else {
                    SettingsTaskDialogButton(
                        "创建资料库",
                        kind: .primary,
                        disabled: flow.operation == .working || flow.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) { chooseLocationAndCreate() }
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

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = FileImportService.supportedUTTypes
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "选择"
        panel.begin { result in if result == .OK { flow.selectedMusicURLs = panel.urls } }
    }

    private func chooseLocationAndCreate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "创建"
        panel.begin { result in
            guard result == .OK, let parent = panel.url else { return }
            let parentAccess = LibraryInitialImportSelection(urls: [parent])
            flow.beginOperation()
            Task {
                defer { parentAccess.release() }
                do {
                    let result = try await appSession.createMusicLibrary(
                        mode: flow.mode,
                        parentURL: parent,
                        displayName: flow.displayName,
                        initialImportSelection: flow.initialImportSelection
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
                } catch {
                    flow.fail("创建失败，请重试。")
                }
            }
        }
    }

    private func openExisting(_ context: LibraryContext) {
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
            } catch {
                flow.fail("无法打开资料库。")
            }
        }
    }
}
