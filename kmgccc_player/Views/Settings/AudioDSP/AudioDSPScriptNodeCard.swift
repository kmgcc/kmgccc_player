//
//  AudioDSPScriptNodeCard.swift
//  myPlayer2
//
//  Expanded editor for a programmable script node. The effect rack owns the
//  node header (enable switch, ordering, removal); this view edits the source
//  and the parameters of the applied script.
//
//  The applied script lives in the persisted DSP configuration, so its
//  parameters are read from there and stay adjustable across launches
//  without compiling again. One action saves, compiles and applies the source.
//

import SwiftUI

@MainActor
struct AudioDSPScriptNodeCard: View {
    let node: DSPNodeConfiguration
    let format: DSPAudioFormat
    let dspController: AudioDSPController
    let scriptController: DSPScriptController
    let onCommit: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var sourceText: String
    @State private var languageVersion: Int
    @State private var values: [String: Double]
    @State private var hasLocalEdits = false
    @State private var isApplying = false
    @State private var isSourceExpanded = false

    private static let collapsedLineCount = 10
    private static let expandedLineLimit = 40
    private static let sourceLineHeight: CGFloat = 15
    private static let sourcePadding: CGFloat = 8

    private var nodeID: UUID { node.nodeID }
    private var draft: DSPScriptDraftDocument? { scriptController.drafts[nodeID] }
    private var activity: DSPScriptNodeActivity {
        scriptController.activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
    }
    private var appliedScript: DSPScriptNodeParameters? { node.scriptParameters }

    private var isDraftDirty: Bool {
        guard let draft else { return true }
        return draft.source != sourceText
            || draft.languageVersion != languageVersion
            || draft.values != values
    }

    private var editorMatchesApplied: Bool {
        guard let appliedScript else { return false }
        return appliedScript.source == sourceText && appliedScript.languageVersion == languageVersion
    }

    /// Parameters declared by the applied script. Reflection is cached by the
    /// compiler, so reading it on every render stays cheap.
    private var appliedParameters: [DSPScriptParameter] {
        guard let appliedScript else { return [] }
        if let declared = try? DSPScriptCompiler.validateSource(
            source: appliedScript.source,
            languageVersion: appliedScript.languageVersion,
            parameterValues: appliedScript.values
        ) {
            return declared
        }
        return (try? DSPScriptCompiler.validateSource(
            source: appliedScript.source,
            languageVersion: appliedScript.languageVersion
        )) ?? []
    }

    init(
        node: DSPNodeConfiguration,
        format: DSPAudioFormat,
        dspController: AudioDSPController,
        scriptController: DSPScriptController,
        onCommit: @escaping () -> Void
    ) {
        self.node = node
        self.format = format
        self.dspController = dspController
        self.scriptController = scriptController
        self.onCommit = onCommit
        let script = node.scriptParameters ?? DSPScriptNodeParameters()
        _sourceText = State(initialValue: script.source)
        _languageVersion = State(initialValue: script.languageVersion)
        _values = State(initialValue: script.values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceEditor
            actionRow
            messages
            parameterControls
        }
        .task(id: nodeID) {
            await loadOrSeedDraft()
        }
        .onChange(of: scriptController.drafts[nodeID]) { _, newDraft in
            guard !hasLocalEdits, let newDraft else { return }
            load(newDraft)
        }
        .onDisappear {
            // Collapsing the node or leaving the page keeps unapplied edits.
            guard hasLocalEdits else { return }
            Task { _ = try? await persistDraftIfNeeded() }
        }
    }

    // MARK: - Source

    private var sourceLineCount: Int {
        sourceText.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    private var sourceEditorHeight: CGFloat {
        let lines = isSourceExpanded
            ? min(max(sourceLineCount, Self.collapsedLineCount), Self.expandedLineLimit)
            : Self.collapsedLineCount
        return CGFloat(lines) * Self.sourceLineHeight + Self.sourcePadding * 2
    }

    private var sourceEditor: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: $sourceText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(Self.sourcePadding)
                .frame(height: sourceEditorHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
                )
                .accessibilityLabel("脚本源码")
                .onChange(of: sourceText) { _, _ in hasLocalEdits = isDraftDirty }

            if sourceLineCount > Self.collapsedLineCount {
                Button(isSourceExpanded ? "收起" : "展开全部") {
                    isSourceExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(action: applySource) {
                HStack(spacing: 6) {
                    if isApplying {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("应用")
                }
            }
            .audioDSPCapsuleButtonStyle()
            .disabled(isApplying || editorMatchesApplied)

            if editorMatchesApplied == false, appliedScript != nil, !isApplying {
                Button("还原") {
                    if let appliedScript {
                        sourceText = appliedScript.source
                        languageVersion = appliedScript.languageVersion
                    }
                }
                .audioDSPCapsuleButtonStyle()
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private var messages: some View {
        if !runtimeWarnings.isEmpty {
            HStack(spacing: 8) {
                Label("脚本运行出错", systemImage: "exclamationmark.circle")
                    .settingsDescriptionStyle()
                Spacer(minLength: 8)
                Button("重试", action: retryRuntimeNode)
                    .audioDSPCapsuleButtonStyle()
            }
        }
        let diagnostics = visibleDiagnostics
        if !diagnostics.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(diagnostics, id: \.self) { diagnostic in
                    Text(diagnostic)
                        .settingsDescriptionStyle()
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var runtimeWarnings: [DSPDiagnostic] {
        dspController.status.warnings.filter {
            $0.nodeID == nodeID && ($0.fieldPath?.hasSuffix(".runtime") ?? false)
        }
    }

    /// Compile, configuration and runtime diagnostics for this node, rendered
    /// once each even when several owners report the same problem.
    private var visibleDiagnostics: [String] {
        var sources = activity.compileDiagnostics
            + dspController.diagnostics.filter { $0.nodeID == nodeID }
            + runtimeWarnings
        if let error = scriptController.lastError, error.nodeID == nodeID {
            sources.append(error)
        }
        var seen = Set<String>()
        return sources.map(describe).filter { seen.insert($0).inserted }
    }

    private func describe(_ diagnostic: DSPDiagnostic) -> String {
        guard let line = diagnostic.line else { return diagnostic.message }
        let position = diagnostic.column.map { "第 \(line) 行第 \($0) 列" } ?? "第 \(line) 行"
        return "\(position)：\(diagnostic.message)"
    }

    // MARK: - Parameters

    @ViewBuilder
    private var parameterControls: some View {
        let parameters = appliedParameters
        if !parameters.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(parameters) { parameter in
                    let span = parameter.maxValue - parameter.minValue
                    DSPRangeSliderRow(
                        title: parameter.name,
                        value: parameterBinding(parameter),
                        range: parameter.minValue...parameter.maxValue,
                        step: max(span / 500, 0.0001),
                        unit: "",
                        fractionDigits: Self.fractionDigits(forSpan: span),
                        onCommit: onCommit
                    )
                }
            }
        }
    }

    private static func fractionDigits(forSpan span: Double) -> Int {
        switch span {
        case ...1: 3
        case ...10: 2
        case ...1_000: 1
        default: 0
        }
    }

    /// Edits the applied script's values in the DSP configuration directly,
    /// which is what persists them.
    private func parameterBinding(_ parameter: DSPScriptParameter) -> Binding<Double> {
        Binding(
            get: { appliedScript?.values[parameter.name] ?? parameter.defaultValue },
            set: { newValue in
                let value = min(parameter.maxValue, max(parameter.minValue, newValue))
                dspController.updateConfiguration { candidate in
                    guard let index = candidate.nodes.firstIndex(where: { $0.nodeID == nodeID }),
                          var script = candidate.nodes[index].scriptParameters else { return }
                    script.values[parameter.name] = value
                    candidate.nodes[index].scriptParameters = script
                }
            }
        )
    }

    // MARK: - Actions

    /// Saves the draft, compiles it and applies it in one step. Current values
    /// carry over for every parameter the new source still declares.
    private func applySource() {
        guard !isApplying else { return }
        isApplying = true
        let declared = (try? DSPScriptCompiler.validateSource(
            source: sourceText,
            languageVersion: languageVersion
        )) ?? []
        let currentValues = appliedScript?.values ?? [:]
        values = declared.reduce(into: [String: Double]()) { result, parameter in
            if let value = currentValues[parameter.name],
               (parameter.minValue...parameter.maxValue).contains(value) {
                result[parameter.name] = value
            }
        }
        Task {
            defer { isApplying = false }
            do {
                let savedDraft = try await persistDraftIfNeeded()
                _ = try await scriptController.compileDraft(
                    nodeID: nodeID,
                    format: format,
                    expectedDraftRevision: savedDraft.revisionString
                )
                _ = try scriptController.applyCompiledDraft(
                    nodeID: nodeID,
                    expectedDraftRevision: savedDraft.revisionString,
                    expectedConfigurationRevision: dspController.revisionString
                )
                hasLocalEdits = false
            } catch {
                // Both owners publish structured diagnostics for this node.
            }
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
}
