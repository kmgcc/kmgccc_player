import SwiftUI

@MainActor
struct AudioDSPScriptNodeCard: View {
    let node: DSPNodeConfiguration
    let index: Int
    let nodeCount: Int
    let format: DSPAudioFormat
    let dspController: AudioDSPController
    let scriptController: DSPScriptController
    @Binding var isExpanded: Bool
    let onEnabledChange: @MainActor @Sendable (Bool) -> Void
    let onChannelPolicyChange: @MainActor @Sendable (String) -> Void
    let onCommit: () -> Void
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    @State private var sourceText: String
    @State private var languageVersion: Int
    @State private var values: [String: Double]
    @State private var hasLocalEdits = false
    @State private var fixtureSelection = "sine"

    private var nodeID: UUID { node.nodeID }
    private var draft: DSPScriptDraftDocument? { scriptController.drafts[nodeID] }
    private var activity: DSPScriptNodeActivity {
        scriptController.activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
    }
    private var policies: [String] {
        ["fullRange", "allChannels"].filter(
            DSPNodeConfiguration.supportedChannelPolicies(forTypeID: node.typeID).contains
        )
    }
    private var isDraftDirty: Bool {
        guard let draft else { return true }
        return draft.source != sourceText
            || draft.languageVersion != languageVersion
            || draft.values != values
    }
    private var compileForCurrentSource: DSPScriptCompileResult? {
        guard let draft,
              draft.source == sourceText,
              draft.languageVersion == languageVersion,
              activity.compileResult?.draftRevision == draft.revisionString else { return nil }
        return activity.compileResult
    }
    private var canApplyCompiledDraft: Bool {
        compileForCurrentSource != nil && !isDraftDirty
    }
    private var activeSourceMatchesEditor: Bool {
        guard let activeNode = dspController.configuration.nodes.first(where: { $0.nodeID == nodeID }),
              let activeScript = activeNode.scriptParameters else { return false }
        return activeScript.source == sourceText && activeScript.languageVersion == languageVersion
    }

    init(
        node: DSPNodeConfiguration,
        index: Int,
        nodeCount: Int,
        format: DSPAudioFormat,
        dspController: AudioDSPController,
        scriptController: DSPScriptController,
        isExpanded: Binding<Bool>,
        onEnabledChange: @escaping @MainActor @Sendable (Bool) -> Void,
        onChannelPolicyChange: @escaping @MainActor @Sendable (String) -> Void,
        onCommit: @escaping () -> Void,
        onMove: @escaping (Int) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.node = node
        self.index = index
        self.nodeCount = nodeCount
        self.format = format
        self.dspController = dspController
        self.scriptController = scriptController
        _isExpanded = isExpanded
        self.onEnabledChange = onEnabledChange
        self.onChannelPolicyChange = onChannelPolicyChange
        self.onCommit = onCommit
        self.onMove = onMove
        self.onRemove = onRemove
        let script = node.scriptParameters ?? DSPScriptNodeParameters()
        _sourceText = State(initialValue: script.source)
        _languageVersion = State(initialValue: script.languageVersion)
        _values = State(initialValue: script.values)
    }

    var body: some View {
        SettingsSection("可编程脚本 \(index + 1)") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSwitchRow(
                    title: "启用脚本",
                    isOn: Binding(get: { node.enabled }, set: onEnabledChange)
                )

                HStack(spacing: 8) {
                    Picker("声道范围", selection: channelPolicyBinding) {
                        if !policies.contains(node.channelPolicy) {
                            Text("当前值：\(node.channelPolicy)").tag(node.channelPolicy)
                        }
                        ForEach(policies, id: \.self) { policy in
                            Text(policyTitle(policy)).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("质量：标准")
                        .settingsDescriptionStyle()
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button { onMove(-1) } label: {
                        Label("上移", systemImage: "chevron.up").labelStyle(.iconOnly)
                    }
                    .dspIconButtonStyle()
                    .accessibilityLabel("上移脚本")
                    .disabled(index == 0)

                    Button { onMove(1) } label: {
                        Label("下移", systemImage: "chevron.down").labelStyle(.iconOnly)
                    }
                    .dspIconButtonStyle()
                    .accessibilityLabel("下移脚本")
                    .disabled(index == nodeCount - 1)

                    Button(role: .destructive, action: onRemove) {
                        Label("移除", systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .dspIconButtonStyle()
                    .accessibilityLabel("移除脚本")
                }

                DisclosureGroup("源码与参数", isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("源码")
                            .settingsDescriptionStyle()
                        TextEditor(text: $sourceText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 150)
                            .accessibilityLabel("脚本源码")
                            .onChange(of: sourceText) { _, _ in hasLocalEdits = isDraftDirty }
                        if isDraftDirty {
                            Text("草稿有未保存的修改")
                                .settingsDescriptionStyle()
                        }

                        HStack(spacing: 8) {
                            Button("保存草稿", action: saveDraft)
                                .audioDSPCapsuleButtonStyle()
                            Button("编译", action: compileDraft)
                                .audioDSPCapsuleButtonStyle()
                                .disabled(activity.compilePhase == .running)
                            Button("应用脚本", action: applyCompiledDraft)
                                .audioDSPCapsuleButtonStyle()
                                .disabled(!canApplyCompiledDraft)
                            if activity.compilePhase == .running {
                                Button("取消") {
                                    scriptController.cancelCompile(
                                        nodeID: nodeID,
                                        requestID: activity.compileRequestID
                                    )
                                }
                                .audioDSPCapsuleButtonStyle()
                            }
                        }

                        if activity.compilePhase == .running {
                            Text("正在编译…")
                                .settingsDescriptionStyle()
                        } else if activity.compilePhase == .failed, activity.compileDiagnostics.isEmpty {
                            Text("编译失败")
                                .settingsDescriptionStyle()
                        }
                        diagnosticList(activity.compileDiagnostics)
                        diagnosticList(dspController.diagnostics.filter { $0.nodeID == nodeID })
                        if !runtimeWarnings.isEmpty {
                            HStack(spacing: 8) {
                                Text("运行错误 · 已旁路")
                                    .settingsDescriptionStyle()
                                Button("重试", action: retryRuntimeNode)
                                    .audioDSPCapsuleButtonStyle()
                            }
                            diagnosticList(runtimeWarnings)
                        }
                        if let error = scriptController.lastError, error.nodeID == nodeID {
                            diagnosticList([error])
                        }

                        if let compileForCurrentSource {
                            compilerSummary(compileForCurrentSource)
                            parameterControls(compileForCurrentSource)
                            fixtureControls
                            if activity.testPhase == .running {
                                Button("取消测试") {
                                    scriptController.cancelTest(
                                        nodeID: nodeID,
                                        requestID: activity.testRequestID
                                    )
                                }
                                .audioDSPCapsuleButtonStyle()
                            } else {
                                Button("运行测试", action: runFixtureTest)
                                    .audioDSPCapsuleButtonStyle()
                                    .disabled(isDraftDirty)
                            }
                            if activity.testPhase == .running {
                                Text("正在运行短时测试…")
                                    .settingsDescriptionStyle()
                            }
                            diagnosticList(activity.testDiagnostics)
                            if activity.testPhase == .failed, activity.testResult != nil {
                                Text("测试发现运行问题")
                                    .settingsDescriptionStyle()
                            } else if activity.testPhase == .failed {
                                Text("测试失败")
                                    .settingsDescriptionStyle()
                            }
                            if let result = activity.testResult {
                                fixtureResult(result)
                            }
                        } else {
                            Text("编译后可查看参数范围并运行短时测试。")
                                .settingsDescriptionStyle()
                        }

                    }
                    .padding(.top, 10)
                }
            }
        }
        .task(id: nodeID) {
            await loadOrSeedDraft()
        }
        .onChange(of: scriptController.drafts[nodeID]) { _, newDraft in
            guard !hasLocalEdits, let newDraft else { return }
            load(newDraft)
        }
    }

    private var channelPolicyBinding: Binding<String> {
        Binding(get: { node.channelPolicy }, set: onChannelPolicyChange)
    }

    private var runtimeWarnings: [DSPDiagnostic] {
        dspController.status.warnings.filter {
            $0.nodeID == nodeID && ($0.fieldPath?.hasSuffix(".runtime") ?? false)
        }
    }

    private var fixtureControls: some View {
        HStack(spacing: 8) {
            Picker("测试信号", selection: $fixtureSelection) {
                Text("静音").tag("silence")
                Text("脉冲").tag("impulse")
                Text("正弦").tag("sine")
                Text("扫频").tag("sweep")
                Text("粉红噪声").tag("pinkNoise")
            }
            .pickerStyle(.menu)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func parameterControls(_ compiled: DSPScriptCompileResult) -> some View {
        if !compiled.parameters.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("参数")
                    .settingsDescriptionStyle()
                ForEach(compiled.parameters) { parameter in
                    DSPRangeSliderRow(
                        title: parameter.name,
                        value: parameterBinding(parameter, compiled: compiled),
                        range: parameter.minValue...parameter.maxValue,
                        step: max((parameter.maxValue - parameter.minValue) / 500, 0.0001),
                        onCommit: { commitParameter(parameter, compiled: compiled) }
                    )
                }
            }
        }
    }

    private func parameterBinding(
        _ parameter: DSPScriptParameter,
        compiled: DSPScriptCompileResult
    ) -> Binding<Double> {
        Binding(
            get: {
                values[parameter.name]
                    ?? compiled.parameterValues[parameter.name]
                    ?? parameter.defaultValue
            },
            set: { newValue in
                let value = min(parameter.maxValue, max(parameter.minValue, newValue))
                values[parameter.name] = value
                hasLocalEdits = true
                guard activeSourceMatchesEditor else { return }
                dspController.updateConfiguration { candidate in
                    guard let index = candidate.nodes.firstIndex(where: { $0.nodeID == nodeID }),
                          var script = candidate.nodes[index].scriptParameters else { return }
                    script.values[parameter.name] = value
                    candidate.nodes[index].scriptParameters = script
                }
            }
        )
    }

    private func commitParameter(
        _ parameter: DSPScriptParameter,
        compiled: DSPScriptCompileResult
    ) {
        guard activeSourceMatchesEditor,
              values[parameter.name] != nil || compiled.parameterValues[parameter.name] != nil else { return }
        onCommit()
    }

    private func compilerSummary(_ result: DSPScriptCompileResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已编译 · \(result.parameters.count) 个参数 · 延迟 \(result.latencyFrames) 帧")
                .settingsDescriptionStyle()
            Text("估算成本 \(result.estimatedWeightedOperationsPerSecond.formatted(.number.precision(.fractionLength(0)))) 次/秒 · 状态 \(result.stateBytes.formatted()) 字节")
                .settingsDescriptionStyle()
        }
    }

    private func fixtureResult(_ result: DSPScriptFixtureResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(fixtureTitle(result.fixtureName)) · \(result.frames.formatted()) 帧 · 输出峰值 \(result.outputPeak.formatted(.number.precision(.fractionLength(4))))")
                .settingsDescriptionStyle()
            Text("实测 \(result.elapsedMilliseconds.formatted(.number.precision(.fractionLength(2)))) ms · 预算等价 \(result.estimatedProcessingMilliseconds.formatted(.number.precision(.fractionLength(2)))) ms · 非有限输出 \(result.nonFiniteOutputSampleCount)")
                .settingsDescriptionStyle()
            if let expectedLatencyFrames = result.expectedLatencyFrames {
                let measuredPeak = result.measuredImpulsePeakFrame.map { "\($0) 帧" } ?? "未检测到"
                Text("声明延迟 \(expectedLatencyFrames) 帧 · 脉冲峰值位置 \(measuredPeak)")
                    .settingsDescriptionStyle()
            }
        }
    }

    private func fixtureTitle(_ name: String) -> String {
        switch name {
        case "silence": "静音"
        case "impulse": "脉冲"
        case "sine": "正弦"
        case "sweep": "扫频"
        case "pinkNoise": "粉红噪声"
        case "customPCM": "自定义 PCM"
        default: name
        }
    }

    @ViewBuilder
    private func diagnosticList(_ diagnostics: [DSPDiagnostic]) -> some View {
        ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
            VStack(alignment: .leading, spacing: 3) {
                if let line = diagnostic.line {
                    Text("\(diagnostic.code) · 第 \(line) 行\(diagnostic.column.map { "，第 \($0) 列" } ?? "")")
                        .settingsDescriptionStyle()
                } else {
                    Text(diagnostic.code)
                        .settingsDescriptionStyle()
                }
                Text(diagnostic.message)
                    .settingsDescriptionStyle()
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func saveDraft() {
        Task {
            do { _ = try await persistDraftIfNeeded() }
            catch { }
        }
    }

    private func compileDraft() {
        Task {
            do {
                let savedDraft = try await persistDraftIfNeeded()
                _ = try await scriptController.compileDraft(
                    nodeID: nodeID,
                    format: format,
                    expectedDraftRevision: savedDraft.revisionString
                )
            } catch {
                // The controller publishes a structured diagnostic for the card.
            }
        }
    }

    private func applyCompiledDraft() {
        guard let draft else { return }
        do {
            _ = try scriptController.applyCompiledDraft(
                nodeID: nodeID,
                expectedDraftRevision: draft.revisionString,
                expectedConfigurationRevision: dspController.revisionString
            )
            hasLocalEdits = false
        } catch {
            // Both owners retain the structured error for the settings status rows.
        }
    }

    private func retryRuntimeNode() {
        do {
            _ = try dspController.apply(dspController.configuration)
            dspController.commitPendingApply()
        } catch {
            // The DSP owner retains the retry diagnostic.
        }
    }

    private func runFixtureTest() {
        Task {
            do {
                let savedDraft = try await persistDraftIfNeeded()
                _ = try await scriptController.testDraft(
                    nodeID: nodeID,
                    format: format,
                    fixture: selectedFixture,
                    expectedDraftRevision: savedDraft.revisionString
                )
            } catch {
                // The controller publishes a structured diagnostic for the card.
            }
        }
    }

    private func persistDraftIfNeeded() async throws -> DSPScriptDraftDocument {
        if !isDraftDirty, let draft { return draft }
        let updated = try await scriptController.updateDraft(
            nodeID: nodeID,
            languageVersion: languageVersion,
            source: sourceText,
            values: values,
            expectedDraftRevision: draft?.revisionString
        )
        load(updated)
        return updated
    }

    private func loadOrSeedDraft() async {
        do {
            if let existing = try await scriptController.getDraft(nodeID: nodeID) {
                if !hasLocalEdits { load(existing) }
                return
            }
            guard let script = node.scriptParameters else { return }
            let created = try await scriptController.updateDraft(
                nodeID: nodeID,
                languageVersion: script.languageVersion,
                source: script.source,
                values: script.values
            )
            if !hasLocalEdits { load(created) }
        } catch {
            // The controller exposes a structured error without losing the node.
        }
    }

    private func load(_ draft: DSPScriptDraftDocument) {
        sourceText = draft.source
        languageVersion = draft.languageVersion
        values = draft.values
        hasLocalEdits = false
    }

    private var selectedFixture: DSPScriptFixture {
        switch fixtureSelection {
        case "silence": .silence(durationSeconds: 0.25)
        case "impulse": .impulse(durationSeconds: 0.25, amplitude: 0.25)
        case "sweep": .sweep(
            durationSeconds: 0.25,
            startFrequencyHz: 30,
            endFrequencyHz: min(18_000, format.sampleRate * 0.45),
            amplitude: 0.25
        )
        case "pinkNoise": .pinkNoise(durationSeconds: 0.25, amplitude: 0.2, seed: 0xD5)
        default: .sine(durationSeconds: 0.25, frequencyHz: 440, amplitude: 0.25)
        }
    }

    private func policyTitle(_ policy: String) -> String {
        switch policy {
        case "fullRange": "全频声道"
        case "allChannels": "所有声道"
        default: policy
        }
    }
}
