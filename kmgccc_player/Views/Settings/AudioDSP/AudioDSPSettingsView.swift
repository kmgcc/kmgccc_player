//
//  AudioDSPSettingsView.swift
//  myPlayer2
//
//  Output devices, the sound each one plays, and that sound's effect chain.
//  Only the device now playing can be edited; others are shown read-only.
//

import PopupKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AudioDSPSettingsView: View {
    var embedsInTab: Bool = false

    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.undoManager) private var undoManager

    @State private var operationError: String?
    @State private var activeDialog: AudioDSPDialogPresentation?
    @State private var presetPendingDeletion: DSPPresetDocument?
    /// Another device's preset chosen for this device; it is copied, never shared.
    @State private var presetPendingCopy: DSPPresetDocument?
    /// The device shown; nil follows the device now playing.
    @State private var viewedDeviceID: String?
    @State private var isShowingImportPicker = false
    @State private var isShowingExportPicker = false
    @State private var presetName = ""
    @State private var presetNameAction: PresetNameAction = .create
    @State private var exportDocument: DSPPresetExportFileDocument?
    @State private var exportFilename = "AudioDSP.json"
    @State private var expandedNodeIDs: Set<UUID> = []
    @State private var presetCompatibilityByID: [UUID: PresetCompatibility] = [:]
    @State private var loadObserverID = UUID()
    @State private var isLoadObserverVisible = false

    private var controller: AudioDSPController { appSession.audioDSPController }
    private var devices: AudioDSPDeviceController { appSession.audioDSPDeviceController }

    private var viewedDevice: DSPOutputDevice? {
        if let viewedDeviceID, let device = devices.devices.first(where: { $0.id == viewedDeviceID }) {
            return device
        }
        return devices.currentDevice
    }

    /// Another device is shown. Its sound can only be set while it plays.
    private var isReadOnly: Bool {
        guard let viewedDevice else { return false }
        return viewedDevice.id != devices.currentDevice?.id
    }

    /// The configuration shown: the live one, or the viewed device's preset.
    private var shownConfiguration: AudioDSPConfiguration {
        guard isReadOnly, let viewedDevice else { return controller.configuration }
        let id = devices.presetID(for: viewedDevice)
        return controller.presets.first { $0.presetID == id }?.configuration ?? .defaultFlat
    }

    var body: some View {
        Group {
            if embedsInTab {
                contentHierarchy
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: SettingsStyleTokens.sectionSpacing) {
                        SettingsHeaderLabel("音效与设备", systemImage: "hifispeaker")
                        contentHierarchy
                    }
                    // Matches the main settings column; the top inset clears the
                    // floating back button.
                    .padding(.horizontal, 32)
                    .padding(.top, 66)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 800, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .tint(themeStore.accentColor)
        .onAppear {
            isLoadObserverVisible = true
            controller.attachUndoManager(undoManager)
            controller.setProcessingLoadVisible(!isReadOnly, observerID: loadObserverID)
            refreshPresetCompatibility()
            // Compile the reverb shaders in the background, so the first card
            // does not wait for them.
            DSPReverbGPU.shared.prepare {}
            Task { await controller.ensureLoaded() }
        }
        .task {
            await devices.ensureLoaded()
            devices.refreshDevices()
        }
        .onChange(of: undoManager) { previous, current in
            controller.detachUndoManager(previous)
            controller.attachUndoManager(current)
        }
        .onChange(of: devices.currentDevice?.id) { _, id in
            if viewedDeviceID == id { viewedDeviceID = nil }
        }
        .onChange(of: isReadOnly) { _, readOnly in
            if isLoadObserverVisible {
                controller.setProcessingLoadVisible(!readOnly, observerID: loadObserverID)
            }
        }
        .onDisappear {
            isLoadObserverVisible = false
            controller.setProcessingLoadVisible(false, observerID: loadObserverID)
            controller.commitPendingApply()
            controller.detachUndoManager(undoManager)
        }
        .alert(
            "是否复制音效以供此设备使用？",
            isPresented: Binding(
                get: { presetPendingCopy != nil },
                set: { if !$0 { presetPendingCopy = nil } }
            ),
            presenting: presetPendingCopy
        ) { preset in
            Button("复制") { selectPresetForCurrentDevice(preset.presetID, copy: true) }
            Button("取消", role: .cancel) {}
        } message: { preset in
            Text("“\(displayName(for: preset))”正用于“\(devices.presetOwner(preset.presetID, excluding: devices.currentDevice)?.name ?? "其他设备")”。")
        }
        .onChange(of: controller.presets) { _, _ in
            refreshPresetCompatibility()
        }
        .onChange(of: controller.status.format) { _, _ in
            refreshPresetCompatibility()
        }
        .alert(
            "无法完成操作",
            isPresented: Binding(
                get: { operationError != nil }, set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("好", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .sheet(item: $activeDialog) { dialog in
            dialogView(for: dialog)
        }
        .alert(
            "删除预设",
            isPresented: Binding(
                get: { presetPendingDeletion != nil },
                set: { if !$0 { presetPendingDeletion = nil } }
            ),
            presenting: presetPendingDeletion
        ) { preset in
            Button("删除", role: .destructive) {
                deletePreset(id: preset.presetID)
            }
            Button("取消", role: .cancel) {}
        } message: { preset in
            Text("“\(preset.name)”将被删除。")
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

    private var contentHierarchy: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.sectionSpacing) {
            deviceSection
            Group {
                linearNodeRackSection
                diagnosticsSection
            }
            .disabled(isReadOnly)
            .opacity(isReadOnly ? 0.5 : 1)
        }
    }

    /// The device first, then the sound it plays.
    private var deviceSection: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 14) {
                AudioDSPDevicePicker(
                    devices: devices.devices,
                    currentID: devices.currentDevice?.id,
                    selectedID: $viewedDeviceID,
                    presetName: { device in
                        let id = devices.presetID(for: device)
                        return controller.presets.first { $0.presetID == id }.map(displayName(for:)) ?? "草稿"
                    }
                )

                if isReadOnly {
                    Text("请使用此设备播放以设置音效。")
                        .settingsDescriptionStyle()
                }

                VStack(alignment: .leading, spacing: 12) {
                    presetRow

                    SettingsSwitchRow(
                        title: "启用音效处理",
                        isOn: configurationBinding(\.enabled)
                    )

                    if !isReadOnly, let notice = statusNotice {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .settingsDescriptionStyle()
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
                            Button("删除") { presetPendingDeletion = preset }
                                .audioDSPCapsuleButtonStyle()
                        }
                    }
                }
                .disabled(isReadOnly)
                .opacity(isReadOnly ? 0.5 : 1)
            }
        }
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            Text("音效").settingsRowLabelStyle()

            Spacer(minLength: 12)

            presetMenu

            Button("新建", systemImage: "plus") {
                beginPresetNameAction(.create)
            }
            .audioDSPCapsuleButtonStyle()

            presetActionsMenu
        }
    }

    /// Every preset is offered. One that plays on another device is copied
    /// for this device after confirmation.
    private var presetMenu: some View {
        let shownName = shownPreset.map(displayName(for:)) ?? "草稿"
        return Menu {
            ForEach(controller.presets) { preset in
                let compatibility = presetCompatibility(for: preset)
                let owner = devices.presetOwner(preset.presetID, excluding: devices.currentDevice)
                Button {
                    if owner != nil {
                        presetPendingCopy = preset
                    } else {
                        selectPresetForCurrentDevice(preset.presetID, copy: false)
                    }
                } label: {
                    let title = presetMenuTitle(for: preset, compatibility: compatibility)
                        + (owner.map { " · \($0.name)" } ?? "")
                    if preset.presetID == shownPreset?.presetID {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
                .disabled(!compatibility.canSelect)
            }
        } label: {
            Text(shownName)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .audioDSPCapsuleButtonStyle()
        .disabled(!devices.isLoaded || devices.currentDevice == nil)
        .accessibilityLabel("音效")
        .help(shownName)
    }

    private var shownPreset: DSPPresetDocument? {
        guard isReadOnly, let viewedDevice else { return selectedPreset }
        let id = devices.presetID(for: viewedDevice)
        return controller.presets.first { $0.presetID == id }
    }

    private var presetActionsMenu: some View {
        Menu {
            Button("重命名", systemImage: "pencil") {
                if let selectedPresetID { beginPresetNameAction(.rename(selectedPresetID)) }
            }
            .disabled(!canEditSelectedPreset)
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
            Divider()
            Button("删除", systemImage: "trash", role: .destructive) {
                presetPendingDeletion = selectedPreset
            }
            .disabled(!canEditSelectedPreset)
        } label: {
            // A borderless menu with its own capsule fill gives a fixed
            // pill; the bordered pop-up style pads an icon-only label unevenly.
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("预设操作")
        .accessibilityLabel("预设操作")
    }

    private var canEditSelectedPreset: Bool {
        selectedPresetID != nil && !isBuiltInSelection
    }

    private var incompatiblePresets: [DSPPresetDocument] {
        controller.presets.filter { !$0.isBuiltIn && !presetCompatibility(for: $0).canSelect }
    }

    private var linearNodeRackSection: some View {
        let shown = shownConfiguration
        return SettingsSection("效果链") {
            HStack(spacing: 10) {
                DSPProcessingLoadBadge(presentation: controller.processingLoad,
                    isEnabled: shown.enabled, isLive: !isReadOnly)
                AudioDSPAddNodeMenu(nodes: shown.nodes) { node in addNode(node) }
            }
        } content: {
            AudioDSPLinearNodeRack(
                nodes: Binding(
                    get: { shownConfiguration.nodes },
                    set: { newNodes in
                        guard !isReadOnly else { return }
                        controller.updateConfiguration(commit: true) { $0.nodes = newNodes }
                    }
                ),
                format: controller.status.format,
                headroomDB: isReadOnly ? nil : controller.status.headroomDB,
                expandedNodeIDs: $expandedNodeIDs,
                inputTrimDB: configurationBinding(\.inputTrimDB, commit: false),
                outputTrimDB: configurationBinding(\.outputTrimDB, commit: false),
                isHeadroomEnabled: headroomEnabledBinding,
                maximumAttenuationDB: maximumAttenuationBinding,
                isLimiterEnabled: limiterEnabledBinding,
                limiterCeilingDB: configurationBinding(\.limiter.ceilingDB, commit: false),
                limiterReleaseMilliseconds: configurationBinding(\.limiter.releaseMilliseconds, commit: false),
                equalLoudness: shown.equalLoudness,
                isLive: !isReadOnly,
                onCommit: controller.commitPendingApply,
                onRemoveNode: { nodeID in removeNode(nodeID) },
                onUpdateNode: { nodeID, mutate in
                    guard !isReadOnly else { return }
                    controller.updateConfiguration { candidate in
                        guard let index = candidate.nodes.firstIndex(where: { $0.nodeID == nodeID }) else { return }
                        mutate(&candidate.nodes[index])
                    }
                },
                onUpdateEqualLoudness: { mutate in
                    guard !isReadOnly else { return }
                    controller.updateConfiguration { mutate(&$0.equalLoudness) }
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

    /// The current device remembers the preset it selects.
    private func selectPresetForCurrentDevice(_ id: UUID, copy: Bool) {
        Task {
            do { try await devices.selectPresetForCurrentDevice(id, copyIfOwned: copy) }
            catch { controller.report(error: error) }
        }
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

    private var headroomEnabledBinding: Binding<Bool> {
        Binding(
            get: { shownConfiguration.headroom.mode == .automatic },
            set: { enabled in
                guard !isReadOnly else { return }
                controller.updateConfiguration(commit: true) { $0.headroom.mode = enabled ? .automatic : .off }
            }
        )
    }

    private var maximumAttenuationBinding: Binding<Double> {
        Binding(
            get: { shownConfiguration.headroom.maximumAttenuationDB },
            set: { value in
                guard !isReadOnly else { return }
                controller.updateConfiguration { $0.headroom.maximumAttenuationDB = value }
            }
        )
    }

    private var limiterEnabledBinding: Binding<Bool> {
        Binding(
            get: { shownConfiguration.limiter.enabled },
            set: { enabled in
                guard !isReadOnly else { return }
                controller.updateConfiguration(commit: true) { $0.limiter.enabled = enabled }
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
            get: { shownConfiguration[keyPath: keyPath] },
            set: { value in
                guard !isReadOnly else { return }
                controller.updateConfiguration(commit: commit) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func addNode(_ node: DSPNodeConfiguration) {
        guard !isReadOnly,
              controller.configuration.nodes.count < AudioDSPConfiguration.maximumNodeCount else { return }
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

    /// Runs after the confirmation dialog. Deleting the current preset returns
    /// the chain to the built-in flat preset rather than keeping a draft.
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
                        operationError = "无法读取预设文件。"
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
                iconColor: themeStore.accentColor,
                onClose: { activeDialog = nil }
            ) {
                TextField("预设名称", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("预设名称")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } footer: {
                Group {
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
            .frame(width: AppPopupStyle().width)

        case .importPreview(let preview):
            SettingsTaskDialog(
                title: "导入预设",
                subtitle: preview.document.name,
                systemImage: "square.and.arrow.down.on.square",
                iconColor: themeStore.accentColor,
                onClose: { activeDialog = nil }
            ) {
                AppPopupScrollRegion {
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
                Group {
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
            .frame(width: AppPopupStyle().width)


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
