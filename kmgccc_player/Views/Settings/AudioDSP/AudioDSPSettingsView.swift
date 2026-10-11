//
//  AudioDSPSettingsView.swift
//  myPlayer2
//
//  DSP enablement, preset management, and supported effect-chain controls.
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AudioDSPSettingsView: View {
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var activeDialog: AudioDSPDialogPresentation?
    @State private var isShowingImportPicker = false
    @State private var isShowingExportPicker = false
    @State private var presetName = ""
    @State private var presetNameAction: PresetNameAction = .create
    @State private var exportDocument: DSPPresetExportFileDocument?
    @State private var exportFilename = "AudioDSP.json"
    @State private var expandedNodeIDs: Set<UUID> = []
    @State private var presetCompatibilityByID: [UUID: PresetCompatibility] = [:]

    private var controller: AudioDSPController { appSession.audioDSPController }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyleTokens.sectionSpacing) {
                SettingsHeaderLabel("音效处理", systemImage: "slider.vertical.3")
                SettingsSection {
                    SettingsSubpageLink(
                        title: "设备音效",
                        subtitle: "按输出设备切换预设",
                        systemImage: "headphones",
                        page: .audioDSPDevices
                    )
                }
                overviewSection
                presetsSection
                linearNodeRackSection
                diagnosticsSection
            }
            // Matches the main settings column; the top inset clears the
            // floating back button.
            .padding(.horizontal, 32)
            .padding(.top, 66)
            .padding(.bottom, 40)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(themeStore.accentColor)
        .onAppear {
            refreshPresetCompatibility()
            Task { await controller.ensureLoaded() }
        }
        .onDisappear { controller.commitPendingApply() }
        .onChange(of: controller.presets) { _, _ in
            refreshPresetCompatibility()
        }
        .onChange(of: controller.status.format) { _, _ in
            refreshPresetCompatibility()
        }
        .sheet(item: $activeDialog) { dialog in
            dialogView(for: dialog)
        }
        .fileImporter(
            isPresented: $isShowingImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleImportSelection
        )
        .fileExporter(
            isPresented: $isShowingExportPicker,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename,
            onCompletion: handleExportCompletion
        )
    }

    private var overviewSection: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSwitchRow(
                    title: "启用音效处理",
                    isOn: configurationBinding(\.enabled)
                )

                if let notice = statusNotice {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .settingsDescriptionStyle()
                }
            }
        }
    }

    private var presetsSection: some View {
        SettingsSection("预设") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    presetNameButton

                    Spacer(minLength: 12)

                    Menu {
                        Picker("切换预设", selection: selectedPresetBinding) {
                            ForEach(controller.presets) { preset in
                                let compatibility = presetCompatibility(for: preset)
                                Text(presetMenuTitle(for: preset, compatibility: compatibility))
                                    .tag(Optional(preset.presetID))
                                    .disabled(!compatibility.canSelect)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Label("切换", systemImage: "arrow.left.arrow.right")
                    }
                    .audioDSPCapsuleButtonStyle()
                    .fixedSize()

                    Button("新建", systemImage: "plus") {
                        beginPresetNameAction(.create)
                    }
                    .audioDSPCapsuleButtonStyle()

                    Menu {
                        Button("复制", systemImage: "plus.square.on.square") {
                            beginPresetNameAction(.copyCurrent)
                        }
                        Divider()
                        Button("导入", systemImage: "square.and.arrow.down") {
                            isShowingImportPicker = true
                        }
                        Button("导出", systemImage: "square.and.arrow.up") {
                            exportSelectedPreset()
                        }
                        .disabled(!canEditSelectedPreset)
                    } label: {
                        Text("更多")
                    }
                    .audioDSPCapsuleButtonStyle()
                    .fixedSize()

                    Button("删除", systemImage: "trash") {
                        if let selectedPresetID { deletePreset(id: selectedPresetID) }
                    }
                    .audioDSPCapsuleButtonStyle()
                    .disabled(!canEditSelectedPreset)
                }

                // Incompatible presets cannot be selected, so they keep their
                // own export and delete actions here.
                ForEach(incompatiblePresets) { preset in
                    HStack(spacing: 8) {
                        Text("“\(preset.name)”与当前版本不兼容")
                            .settingsDescriptionStyle()
                        Spacer(minLength: 8)
                        Button("导出") { exportPreset(preset) }
                            .audioDSPCapsuleButtonStyle()
                        Button("删除") { deletePreset(id: preset.presetID) }
                            .audioDSPCapsuleButtonStyle()
                    }
                }
            }
        }
    }

    /// The current preset's name; clicking it renames a user preset.
    private var presetNameButton: some View {
        Button {
            if let selectedPresetID, canEditSelectedPreset {
                beginPresetNameAction(.rename(selectedPresetID))
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedPreset.map(displayName(for:)) ?? "草稿")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if canEditSelectedPreset {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canEditSelectedPreset)
        .help(canEditSelectedPreset ? "重命名" : "")
        .accessibilityLabel("当前预设")
        .accessibilityValue(selectedPreset.map(displayName(for:)) ?? "草稿")
        .accessibilityHint(canEditSelectedPreset ? "重命名" : "")
    }

    private var canEditSelectedPreset: Bool {
        selectedPresetID != nil && !isBuiltInSelection
    }

    private var incompatiblePresets: [DSPPresetDocument] {
        controller.presets.filter { !$0.isBuiltIn && !presetCompatibility(for: $0).canSelect }
    }

    private var linearNodeRackSection: some View {
        SettingsSection("效果链") {
            AudioDSPAddNodeMenu(nodes: controller.configuration.nodes) { node in addNode(node) }
        } content: {
            AudioDSPLinearNodeRack(
                nodes: Binding(
                    get: { controller.configuration.nodes },
                    set: { newNodes in
                        controller.updateConfiguration(commit: true) { $0.nodes = newNodes }
                    }
                ),
                format: controller.status.format,
                headroomDB: controller.status.headroomDB,
                expandedNodeIDs: $expandedNodeIDs,
                inputTrimDB: configurationBinding(\.inputTrimDB, commit: false),
                outputTrimDB: configurationBinding(\.outputTrimDB, commit: false),
                headroomMode: headroomModeBinding,
                headroomMarginDB: headroomMarginBinding,
                onCommit: controller.commitPendingApply,
                onRemoveNode: { nodeID in removeNode(nodeID) },
                onUpdateNode: { nodeID, mutate in
                    controller.updateConfiguration { candidate in
                        guard let index = candidate.nodes.firstIndex(where: { $0.nodeID == nodeID }) else { return }
                        mutate(&candidate.nodes[index])
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        if let lastError = pageLevelError {
            SettingsSection("状态信息") {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(lastError.message, systemImage: "exclamationmark.circle")
                        .settingsDescriptionStyle()
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("清除") {
                        controller.clearErrors()
                        appSession.audioDSPScriptController.clearDiagnostics()
                    }
                    .audioDSPCapsuleButtonStyle()
                }
            }
        } else if !displayDiagnostics.isEmpty {
            SettingsSection("状态信息") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(displayDiagnostics) { diagnostic in
                        Label(diagnostic.message, systemImage: "info.circle")
                            .settingsDescriptionStyle()
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// Script errors tied to a node in the chain appear inside that node's
    /// editor, so the page only repeats errors that have no other home.
    private var pageLevelError: DSPDiagnostic? {
        if let error = controller.lastError { return error }
        guard let scriptError = appSession.audioDSPScriptController.lastError else { return nil }
        if let nodeID = scriptError.nodeID, isScriptNodeInChain(nodeID) { return nil }
        return scriptError
    }

    private func isScriptNodeInChain(_ nodeID: UUID) -> Bool {
        controller.configuration.nodes.contains {
            $0.nodeID == nodeID && $0.typeID == DSPNodeConfiguration.scriptTypeID
        }
    }

    private func presetCompatibility(for preset: DSPPresetDocument) -> PresetCompatibility {
        if let cached = presetCompatibilityByID[preset.presetID],
           cached.revisionString == preset.revisionString,
           cached.format == controller.status.format {
            return cached
        }
        return makePresetCompatibility(for: preset)
    }

    private func refreshPresetCompatibility() {
        var compatibilityByID: [UUID: PresetCompatibility] = [:]
        for preset in controller.presets {
            compatibilityByID[preset.presetID] = presetCompatibility(for: preset)
        }
        presetCompatibilityByID = compatibilityByID
    }

    private func makePresetCompatibility(for preset: DSPPresetDocument) -> PresetCompatibility {
        guard preset.schemaVersion == DSPPresetDocument.schemaVersion else {
            return PresetCompatibility(
                revisionString: preset.revisionString,
                format: controller.status.format,
                diagnostics: [DSPDiagnostic(
                    code: "dsp.presetIncompatible",
                    message: DSPPresetStoreError.unsupportedSchema(preset.schemaVersion).localizedDescription,
                    fieldPath: "schemaVersion"
                )]
            )
        }
        do {
            _ = try controller.validate(preset.configuration)
            return PresetCompatibility(revisionString: preset.revisionString,
                format: controller.status.format, diagnostics: [])
        } catch let error as DSPConfigurationValidationError {
            return PresetCompatibility(revisionString: preset.revisionString,
                format: controller.status.format, diagnostics: error.diagnostics)
        } catch {
            return PresetCompatibility(revisionString: preset.revisionString,
                format: controller.status.format, diagnostics: [DSPDiagnostic(
                code: "dsp.presetIncompatible",
                message: error.localizedDescription
            )])
        }
    }

    /// Renderer warnings and diagnostics. Script compile, test and runtime
    /// messages are shown inside their node's editor instead.
    private var displayDiagnostics: [DSPDiagnostic] {
        var seen = Set<String>()
        return (controller.status.warnings + controller.status.diagnostics)
            .filter { diagnostic in
                guard let nodeID = diagnostic.nodeID else { return true }
                return !isScriptNodeInChain(nodeID)
            }
            .filter { seen.insert($0.id).inserted }
    }

    private func presetMenuTitle(for preset: DSPPresetDocument, compatibility: PresetCompatibility) -> String {
        displayName(for: preset) + (compatibility.canSelect ? "" : "（不兼容）")
    }

    private var selectedPresetBinding: Binding<UUID?> {
        Binding(
            get: { controller.selectedPresetID },
            set: { id in
                guard let id else { return }
                do {
                    let expectedPresetRevision = controller.presets.first(where: { $0.presetID == id })?.revisionString
                    _ = try controller.selectPreset(
                        id: id,
                        expectedRevision: controller.revisionString,
                        expectedPresetRevision: expectedPresetRevision
                    )
                } catch {
                    controller.report(error: error)
                }
            }
        )
    }

    private var selectedPresetID: UUID? {
        controller.selectedPresetID
    }

    private var selectedPreset: DSPPresetDocument? {
        guard let id = selectedPresetID else { return nil }
        return controller.presets.first(where: { $0.presetID == id })
    }

    private var isBuiltInSelection: Bool {
        selectedPreset?.isBuiltIn == true
    }

    private var headroomModeBinding: Binding<DSPHeadroomMode> {
        Binding(
            get: { controller.configuration.headroom.mode },
            set: { mode in
                controller.updateConfiguration(commit: true) { $0.headroom.mode = mode }
            }
        )
    }

    private var headroomMarginBinding: Binding<Double> {
        Binding(
            get: { controller.configuration.headroom.marginDB },
            set: { value in
                controller.updateConfiguration { $0.headroom.marginDB = value }
            }
        )
    }

    /// Shown only when the switch alone would mislead: processing is on but
    /// not reaching the output. Normal states are evident from the switch.
    private var statusNotice: String? {
        guard controller.configuration.enabled else { return nil }
        switch controller.status.state {
        case .failed: return "当前设置未能生效"
        case .inactiveExternalSource: return "外部播放来源暂不支持音效处理"
        case .ready, .preparing, .scheduled, .audible, .superseded: return nil
        }
    }

    private var presetNameDialogTitle: String {
        switch presetNameAction {
        case .create: "新建预设"
        case .copyCurrent: "复制预设"
        case .rename: "重命名预设"
        case .duplicate: "复制预设"
        }
    }

    private var presetNameConfirmTitle: String {
        switch presetNameAction {
        case .create: "新建"
        case .copyCurrent: "复制"
        case .rename: "重命名"
        case .duplicate: "复制"
        }
    }

    private func configurationBinding<Value>(
        _ keyPath: WritableKeyPath<AudioDSPConfiguration, Value>,
        commit: Bool = true
    ) -> Binding<Value> {
        Binding(
            get: { controller.configuration[keyPath: keyPath] },
            set: { value in
                controller.updateConfiguration(commit: commit) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func addNode(_ node: DSPNodeConfiguration) {
        guard controller.configuration.nodes.count < AudioDSPConfiguration.maximumNodeCount else { return }
        if node.typeID == DSPNodeConfiguration.scriptTypeID,
           controller.configuration.nodes.filter({ $0.typeID == DSPNodeConfiguration.scriptTypeID }).count >= 4 {
            return
        }
        controller.updateConfiguration(commit: true) { $0.nodes.append(node) }
        expandedNodeIDs.insert(node.nodeID)
    }

    private func displayName(for document: DSPPresetDocument) -> String {
        guard document.isBuiltIn else { return document.name }
        return NSLocalizedString(
            "dsp.preset.flat",
            value: "Flat",
            comment: "Name of the built-in flat audio DSP preset."
        )
    }

    private func beginPresetNameAction(_ action: PresetNameAction) {
        presetNameAction = action
        switch action {
        case .create:
            presetName = "新预设"
        case .copyCurrent:
            presetName = selectedPreset.map { "\(displayName(for: $0)) 副本" } ?? "我的预设"
        case .rename(let id), .duplicate(let id):
            presetName = controller.presets.first(where: { $0.presetID == id }).map {
                action.isDuplicate ? "\(displayName(for: $0)) 副本" : $0.name
            } ?? "我的预设"
        }
        activeDialog = .presetName(action)
    }

    private func performPresetNameAction() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch presetNameAction {
        case .create:
            Task {
                do { _ = try await controller.createPreset(name: name) }
                catch { controller.report(error: error) }
            }
        case .copyCurrent:
            Task {
                do { _ = try await controller.copyCurrentPreset(name: name) }
                catch { controller.report(error: error) }
            }
        case .rename(let id):
            guard let document = controller.presets.first(where: { $0.presetID == id }) else { return }
            Task {
                do {
                    _ = try await controller.renamePreset(
                        id: id,
                        name: name,
                        expectedPresetRevision: document.revisionString
                    )
                } catch {
                    controller.report(error: error)
                }
            }
        case .duplicate(let id):
            guard let document = controller.presets.first(where: { $0.presetID == id }) else { return }
            Task {
                do {
                    let copied = try await controller.duplicatePreset(
                        id: id,
                        name: name,
                        expectedPresetRevision: document.revisionString
                    )
                    _ = try controller.selectPreset(id: copied.presetID)
                    controller.commitPendingApply()
                } catch {
                    controller.report(error: error)
                }
            }
        }
    }

    /// Deletes without confirmation. Deleting the current preset returns the
    /// chain to the built-in flat preset rather than keeping a draft.
    private func deletePreset(id: UUID) {
        guard let document = controller.presets.first(where: { $0.presetID == id }), !document.isBuiltIn else { return }
        let wasSelected = controller.selectedPresetID == id
        Task {
            do {
                try await controller.deletePreset(
                    id: document.presetID,
                    expectedPresetRevision: document.revisionString
                )
                if wasSelected, controller.selectedPresetID == nil {
                    _ = try controller.selectPreset(id: DSPPresetDocument.flatPresetID)
                    controller.commitPendingApply()
                }
            } catch {
                controller.report(error: error)
            }
        }
    }

    private func removeNode(_ nodeID: UUID) {
        controller.updateConfiguration(commit: true) { candidate in
            candidate.nodes.removeAll(where: { $0.nodeID == nodeID })
        }
        expandedNodeIDs.remove(nodeID)
    }

    private func exportSelectedPreset() {
        guard let selectedPreset else { return }
        exportPreset(selectedPreset)
    }

    private func exportPreset(_ preset: DSPPresetDocument) {
        exportFilename = "\(preset.name).json"
        Task {
            do {
                exportDocument = DSPPresetExportFileDocument(
                    data: try await controller.exportPreset(id: preset.presetID)
                )
                isShowingExportPicker = true
            } catch {
                controller.report(error: error)
            }
        }
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasScope = url.startAccessingSecurityScopedResource()
            Task {
                defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard let preview = try await controller.importPreview(from: url) else {
                        activeDialog = .error("无法读取预设文件。")
                        return
                    }
                    activeDialog = .importPreview(preview)
                } catch {
                    controller.report(error: error)
                }
            }
        case .failure(let error):
            controller.report(error: error)
        }
    }

    private func importReviewedPreset(_ preview: DSPPresetImportPreview) {
        Task {
            do {
                _ = try await controller.importPreset(preview)
            } catch {
                controller.report(error: error)
            }
        }
    }

    @ViewBuilder
    private func dialogView(for dialog: AudioDSPDialogPresentation) -> some View {
        switch dialog {
        case .presetName:
            SettingsTaskDialog(
                title: presetNameDialogTitle,
                subtitle: "为当前音效配置命名",
                systemImage: "slider.horizontal.3",
                iconColor: themeStore.accentColor
            ) {
                TextField("预设名称", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("预设名称")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } footer: {
                HStack {
                    Spacer()
                    SettingsTaskDialogButton("取消", kind: .secondary) {
                        activeDialog = nil
                    }
                    SettingsTaskDialogButton(
                        presetNameConfirmTitle,
                        kind: .primary,
                        disabled: presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        performPresetNameAction()
                        activeDialog = nil
                    }
                }
            }
            .frame(minWidth: 460, idealWidth: 500, maxWidth: 560)

        case .importPreview(let preview):
            SettingsTaskDialog(
                title: "导入预设",
                subtitle: preview.document.name,
                systemImage: "square.and.arrow.down.on.square",
                iconColor: themeStore.accentColor
            ) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if preview.canImport && !preview.isCompatible {
                            Text("可保留为未兼容预设。")
                                .settingsDescriptionStyle()
                        } else if preview.warnings.isEmpty && preview.diagnostics.isEmpty {
                            Text("预设可导入。")
                                .settingsDescriptionStyle()
                        }
                        ForEach(preview.warnings + preview.diagnostics) { diagnostic in
                            Label(diagnostic.message, systemImage: "info.circle")
                                .fixedSize(horizontal: false, vertical: true)
                                .settingsDescriptionStyle()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 50, maxHeight: 240)
            } footer: {
                HStack {
                    Spacer()
                    SettingsTaskDialogButton("取消", kind: .secondary) {
                        activeDialog = nil
                    }
                    SettingsTaskDialogButton(
                        preview.isCompatible ? "导入" : "保留预设",
                        kind: .primary,
                        disabled: !preview.canImport
                    ) {
                        importReviewedPreset(preview)
                        activeDialog = nil
                    }
                }
            }
            .frame(minWidth: 460, idealWidth: 500, maxWidth: 560)

        case .error(let message):
            SettingsTaskDialog(
                title: "无法完成操作",
                subtitle: message,
                systemImage: "exclamationmark.circle",
                iconColor: themeStore.accentColor
            ) {
                EmptyView()
                    .frame(minHeight: 12)
            } footer: {
                HStack {
                    Spacer()
                    SettingsTaskDialogButton("好", kind: .primary) {
                        activeDialog = nil
                    }
                }
            }
            .frame(minWidth: 460, idealWidth: 500, maxWidth: 560)
        }
    }

    private func handleExportCompletion(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            controller.report(error: error)
        }
        exportDocument = nil
    }

    private enum PresetNameAction {
        case create
        case copyCurrent
        case rename(UUID)
        case duplicate(UUID)

        var isDuplicate: Bool {
            if case .duplicate = self { return true }
            return false
        }
    }

    private struct PresetCompatibility {
        let revisionString: String
        let format: DSPAudioFormat?
        let diagnostics: [DSPDiagnostic]

        var canSelect: Bool { diagnostics.isEmpty }
    }

    private enum AudioDSPDialogPresentation: Identifiable {
        case presetName(PresetNameAction)
        case importPreview(DSPPresetImportPreview)
        case error(String)

        var id: String {
            switch self {
            case .presetName(let action):
                switch action {
                case .create: "preset-name-create"
                case .copyCurrent: "preset-name-copy-current"
                case .rename(let id): "preset-name-rename-\(id.uuidString)"
                case .duplicate(let id): "preset-name-duplicate-\(id.uuidString)"
                }
            case .importPreview(let preview): "import-\(preview.document.presetID.uuidString)-\(preview.document.revisionString)"
            case .error: "error"
            }
        }
    }
}

extension View {
    func audioDSPCapsuleButtonStyle() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .clipShape(Capsule())
            .controlSize(.regular)
    }
}

private struct DSPPresetExportFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
