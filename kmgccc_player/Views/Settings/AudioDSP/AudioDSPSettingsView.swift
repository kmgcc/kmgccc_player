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
    @State private var presetNameAction: PresetNameAction = .saveAs
    @State private var exportDocument: DSPPresetExportFileDocument?
    @State private var exportFilename = "AudioDSP.json"
    @State private var expandedNodeIDs: Set<UUID> = []
    @State private var presetCompatibilityByID: [UUID: PresetCompatibility] = [:]

    private var controller: AudioDSPController { appSession.audioDSPController }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                enablementSection
                presetsSection
                linearNodeRackSection
                diagnosticsSection
            }
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 52)
            .padding(.bottom, 32)
        }
        .tint(themeStore.accentColor)
        .onAppear {
            refreshPresetCompatibility()
            Task { await controller.ensureLoaded() }
        }
        .onChange(of: controller.presets) { _, _ in
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

    private var enablementSection: some View {
        SettingsSection("处理状态") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSwitchRow(
                    title: "启用音效处理",
                    isOn: configurationBinding(\.enabled)
                )

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusTitle)
                        .settingsDescriptionStyle()
                    Spacer(minLength: 8)
                    if controller.isModified {
                        Text("已修改")
                            .settingsDescriptionStyle()
                            .accessibilityLabel("当前预设已修改")
                    }
                }

                if let format = controller.status.format {
                    HStack {
                        Text("当前格式")
                        Spacer()
                        Text(formatDescription(format))
                    }
                    .settingsDescriptionStyle()
                    if !format.layoutIsKnown {
                        Text("声道布局未知")
                            .settingsDescriptionStyle()
                    }
                }
            }
        }
    }

    private var presetsSection: some View {
        SettingsSection("预设") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("当前预设", selection: selectedPresetBinding) {
                    ForEach(controller.presets) { preset in
                        let compatibility = presetCompatibility(for: preset)
                        Text(displayName(for: preset) + (compatibility.canSelect ? "" : "（不兼容）"))
                            .tag(Optional(preset.presetID))
                            .disabled(!compatibility.canSelect)
                    }
                    if controller.selectedPresetID == nil {
                        Text("未保存草稿").tag(Optional<UUID>.none)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("当前预设")

                HStack(spacing: 8) {
                    Button(action: saveCurrentPreset) {
                        Label("保存", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!controller.isModified && !isBuiltInSelection)
                    .audioDSPCapsuleButtonStyle()

                    Button("另存为", action: { beginPresetNameAction(.saveAs) })
                        .audioDSPCapsuleButtonStyle()

                    Menu("更多") {
                        Button("复制", systemImage: "plus.square.on.square") {
                            beginPresetNameAction(.duplicate(selectedPresetID ?? DSPPresetDocument.flatPresetID))
                        }
                        Button("重命名", systemImage: "pencil") {
                            beginPresetNameAction(.rename(selectedPresetID ?? DSPPresetDocument.flatPresetID))
                        }
                        .disabled(isBuiltInSelection || selectedPresetID == nil)
                        Button("删除", systemImage: "trash", role: .destructive) {
                            if let selectedPreset {
                                activeDialog = .deletePreset(selectedPreset.presetID)
                            }
                        }
                        .disabled(isBuiltInSelection || selectedPresetID == nil)
                        Divider()
                        Menu("管理预设") {
                            ForEach(controller.presets.filter { !$0.isBuiltIn }) { preset in
                                let compatibility = presetCompatibility(for: preset)
                                Menu {
                                    if let diagnostic = compatibility.diagnostics.first {
                                        Button("不兼容：\(diagnostic.message)") {}
                                            .disabled(true)
                                        if compatibility.diagnostics.count > 1 {
                                            Button("还有 \(compatibility.diagnostics.count - 1) 项诊断") {}
                                                .disabled(true)
                                        }
                                        Divider()
                                    }
                                    Button("重命名") { beginPresetNameAction(.rename(preset.presetID)) }
                                    Button("复制") { beginPresetNameAction(.duplicate(preset.presetID)) }
                                    Button("导出 JSON…") { exportPreset(preset) }
                                    Button("删除", role: .destructive) { activeDialog = .deletePreset(preset.presetID) }
                                } label: {
                                    Text(displayName(for: preset) + (compatibility.canSelect ? "" : "（不兼容）"))
                                }
                            }
                        }
                        .disabled(controller.presets.allSatisfy(\.isBuiltIn))
                        Button("导入 JSON…", systemImage: "square.and.arrow.down.on.square") {
                            isShowingImportPicker = true
                        }
                        Button("导出 JSON…", systemImage: "square.and.arrow.up.on.square") {
                            exportSelectedPreset()
                        }
                        .disabled(selectedPresetID == nil)
                    }
                    .audioDSPCapsuleButtonStyle()
                }
            }
        }
    }

    private var linearNodeRackSection: some View {
        SettingsSection("效果链") {
            AudioDSPLinearNodeRack(
                nodes: Binding(
                    get: { controller.configuration.nodes },
                    set: { newNodes in
                        controller.updateConfiguration(commit: true) { $0.nodes = newNodes }
                    }
                ),
                configuration: controller.configuration,
                format: controller.status.format,
                headroomDB: controller.status.headroomDB,
                expandedNodeIDs: $expandedNodeIDs,
                inputTrimDB: configurationBinding(\.inputTrimDB, commit: false),
                outputTrimDB: configurationBinding(\.outputTrimDB, commit: false),
                headroomMode: headroomModeBinding,
                headroomMarginDB: headroomMarginBinding,
                onCommit: controller.commitPendingApply,
                onAddNode: { node in addNode(node) },
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
        if let lastError = controller.lastError ?? appSession.audioDSPScriptController.lastError {
            SettingsSection("状态信息") {
                HStack(alignment: .top, spacing: 10) {
                    Label(lastError.message, systemImage: "exclamationmark.circle")
                        .fixedSize(horizontal: false, vertical: true)
                        .settingsDescriptionStyle()
                    Spacer(minLength: 4)
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
                            .fixedSize(horizontal: false, vertical: true)
                            .settingsDescriptionStyle()
                    }
                }
            }
        }
    }

    private func presetCompatibility(for preset: DSPPresetDocument) -> PresetCompatibility {
        if let cached = presetCompatibilityByID[preset.presetID],
           cached.revisionString == preset.revisionString {
            return cached
        }
        return makePresetCompatibility(for: preset)
    }

    private func refreshPresetCompatibility() {
        var compatibilityByID: [UUID: PresetCompatibility] = [:]
        for preset in controller.presets {
            compatibilityByID[preset.presetID] = makePresetCompatibility(for: preset)
        }
        presetCompatibilityByID = compatibilityByID
    }

    private func makePresetCompatibility(for preset: DSPPresetDocument) -> PresetCompatibility {
        guard preset.schemaVersion == DSPPresetDocument.schemaVersion else {
            return PresetCompatibility(
                revisionString: preset.revisionString,
                diagnostics: [DSPDiagnostic(
                    code: "dsp.presetIncompatible",
                    message: DSPPresetStoreError.unsupportedSchema(preset.schemaVersion).localizedDescription,
                    fieldPath: "schemaVersion"
                )]
            )
        }
        do {
            _ = try controller.validate(preset.configuration)
            return PresetCompatibility(revisionString: preset.revisionString, diagnostics: [])
        } catch let error as DSPConfigurationValidationError {
            return PresetCompatibility(revisionString: preset.revisionString, diagnostics: error.diagnostics)
        } catch {
            return PresetCompatibility(revisionString: preset.revisionString, diagnostics: [DSPDiagnostic(
                code: "dsp.presetIncompatible",
                message: error.localizedDescription
            )])
        }
    }

    private var displayDiagnostics: [DSPDiagnostic] {
        var seen = Set<String>()
        let scriptDiagnostics = appSession.audioDSPScriptController.activityByNodeID.values.flatMap {
            $0.compileDiagnostics + $0.testDiagnostics
        }
        return (controller.status.warnings + controller.status.diagnostics + scriptDiagnostics)
            .filter { seen.insert($0.id).inserted }
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

    private var statusTitle: String {
        switch controller.status.state {
        case .ready: "就绪"
        case .preparing: "正在准备"
        case .scheduled: "已排队"
        case .audible: "已应用"
        case .superseded: "已由新设置替代"
        case .failed: "应用失败"
        case .inactiveExternalSource: "外部来源未处理"
        }
    }

    private var statusColor: Color {
        switch controller.status.state {
        case .failed: .secondary
        case .inactiveExternalSource, .superseded: .secondary
        case .ready, .preparing, .scheduled, .audible: themeStore.accentColor
        }
    }

    private var presetNameDialogTitle: String {
        switch presetNameAction {
        case .saveAs: "另存预设"
        case .rename: "重命名预设"
        case .duplicate: "复制预设"
        }
    }

    private var presetNameConfirmTitle: String {
        switch presetNameAction {
        case .saveAs: "保存"
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

    private func expansionBinding(for nodeID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedNodeIDs.contains(nodeID) },
            set: { isExpanded in
                if isExpanded {
                    expandedNodeIDs.insert(nodeID)
                } else {
                    expandedNodeIDs.remove(nodeID)
                }
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

    private var scriptCompileFormat: DSPAudioFormat {
        controller.status.format ?? DSPAudioFormat(
            sampleRate: 48_000,
            channelCount: 2,
            rawLayoutData: nil,
            channelLabels: nil,
            layoutIsKnown: false
        )
    }

    private func formatDescription(_ format: DSPAudioFormat) -> String {
        let sampleRate = format.sampleRate / 1_000
        let formattedSampleRate = sampleRate.formatted(.number.precision(.fractionLength(1)))
        return "\(formattedSampleRate) kHz · \(format.channelCount) 声道"
    }

    private func formatLatency(frames: Int) -> String {
        let frameValue = "\(frames) 帧"
        guard let sampleRate = controller.status.format?.sampleRate,
              sampleRate.isFinite, sampleRate > 0 else { return frameValue }
        let milliseconds = (Double(frames) / sampleRate * 1_000)
            .formatted(.number.precision(.fractionLength(2)))
        return "\(frameValue) · \(milliseconds) ms"
    }

    private func statusDetailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .settingsDescriptionStyle()
    }

    private func peakGuaranteeTitle(_ value: String) -> String {
        switch value {
        case "bypassed": "原始旁路"
        case "estimatedLinearResponse": "线性频响估算"
        case "unavailable": "非线性峰值待测"
        default: "峰值信息不可用"
        }
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
        case .saveAs:
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
        case .saveAs:
            Task {
                do { _ = try await controller.savePreset(name: name) }
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
                    _ = try await controller.duplicatePreset(
                        id: id,
                        name: name,
                        expectedPresetRevision: document.revisionString
                    )
                } catch {
                    controller.report(error: error)
                }
            }
        }
    }

    private func saveCurrentPreset() {
        guard let document = selectedPreset, !document.isBuiltIn else {
            beginPresetNameAction(.saveAs)
            return
        }
        Task {
            do {
                _ = try await controller.savePreset(
                    name: document.name,
                    id: document.presetID,
                    expectedPresetRevision: document.revisionString
                )
            } catch {
                controller.report(error: error)
            }
        }
    }

    private func deleteSelectedPreset(id: UUID) {
        guard let document = controller.presets.first(where: { $0.presetID == id }), !document.isBuiltIn else { return }
        Task {
            do {
                try await controller.deletePreset(
                    id: document.presetID,
                    expectedPresetRevision: document.revisionString
                )
            } catch {
                controller.report(error: error)
            }
        }
    }

    private func moveNode(_ nodeID: UUID, by offset: Int) {
        controller.updateConfiguration(commit: true) { candidate in
            guard let index = candidate.nodes.firstIndex(where: { $0.nodeID == nodeID }) else { return }
            let destination = index + offset
            guard candidate.nodes.indices.contains(destination) else { return }
            candidate.nodes.swapAt(index, destination)
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

        case .deletePreset(let presetID):
            SettingsTaskDialog(
                title: "删除预设",
                subtitle: controller.selectedPresetID == presetID
                    ? "当前声音会保留为未保存草稿。" : "删除保存的音效配置。",
                systemImage: "trash",
                iconColor: themeStore.accentColor
            ) {
                EmptyView()
                    .frame(minHeight: 12)
            } footer: {
                HStack {
                    Spacer()
                    SettingsTaskDialogButton("取消", kind: .secondary) {
                        activeDialog = nil
                    }
                    SettingsTaskDialogButton("删除", kind: .destructive) {
                        deleteSelectedPreset(id: presetID)
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
        case saveAs
        case rename(UUID)
        case duplicate(UUID)

        var isDuplicate: Bool {
            if case .duplicate = self { return true }
            return false
        }
    }

    private struct PresetCompatibility {
        let revisionString: String
        let diagnostics: [DSPDiagnostic]

        var canSelect: Bool { diagnostics.isEmpty }
    }

    private enum AudioDSPDialogPresentation: Identifiable {
        case presetName(PresetNameAction)
        case deletePreset(UUID)
        case importPreview(DSPPresetImportPreview)
        case error(String)

        var id: String {
            switch self {
            case .presetName(let action):
                switch action {
                case .saveAs: "preset-name-save"
                case .rename(let id): "preset-name-rename-\(id.uuidString)"
                case .duplicate(let id): "preset-name-duplicate-\(id.uuidString)"
                }
            case .deletePreset(let id): "delete-\(id.uuidString)"
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
