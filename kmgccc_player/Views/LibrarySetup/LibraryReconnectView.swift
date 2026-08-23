import AppKit
import SwiftUI

struct LibraryReconnectView: View {
    enum Target: Equatable {
        case libraryRoot(libraryID: UUID, mode: MusicLibraryMode)
        case sources(libraryID: UUID, sourceIDs: [UUID])
    }

    @Bindable var flow: LibrarySetupViewModel
    let target: Target
    let onChange: @MainActor () async -> Void
    let onRequestClose: () -> Void

    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var retainedSelection: LibraryInitialImportSelection?
    @State private var sourceIndex = 0
    @State private var preparation: SourceReconnectPreparation?
    @State private var selectedPlanID = ""
    @State private var conflictSelections: [UUID: String] = [:]

    var body: some View {
        SettingsTaskDialog(
            title: title,
            subtitle: subtitle,
            systemImage: icon,
            iconColor: themeStore.accentColor
        ) {
            content
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        } footer: {
            HStack {
                SettingsTaskDialogButton("取消", kind: .secondary) { cancel() }
                Spacer()
                primaryButton
            }
        }
        .frame(width: 500)
        .interactiveDismissDisabled(flow.operation == .working)
        .onDisappear {
            if flow.presentation == .none {
                retainedSelection?.release()
                retainedSelection = nil
            }
        }
    }

    private var title: String {
        switch target {
        case .libraryRoot: return "重新连接资料库"
        case .sources: return "重新连接来源"
        }
    }

    private var subtitle: String {
        switch target {
        case .libraryRoot:
            return "选择原资料库的当前位置。"
        case let .sources(_, sourceIDs):
            return "来源 \(min(sourceIndex + 1, sourceIDs.count)) / \(sourceIDs.count)"
        }
    }

    private var icon: String {
        switch target {
        case .libraryRoot: return "externaldrive.badge.questionmark"
        case .sources: return "folder.badge.questionmark"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch target {
        case let .libraryRoot(_, mode):
            ContentUnavailableView(
                mode == .managed ? "找不到资料库" : "资料库已断开",
                systemImage: "externaldrive.badge.questionmark",
                description: Text("所选位置必须包含原资料库。")
            )
        case .sources:
            sourceContent
        }
    }

    @ViewBuilder
    private var sourceContent: some View {
        if let preparation, let plan = selectedPlan(in: preparation) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if preparation.plans.count > 1 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("候选位置")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            AppDialogOptionMenu(
                                selection: $selectedPlanID,
                                options: preparation.plans.map { plan in
                                    AppDialogOption(value: plan.id, label: plan.rootURL.path)
                                }
                            )
                        }
                    } else {
                        LabeledContent("候选位置") {
                            Text(plan.rootURL.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    HStack(spacing: 14) {
                        Label("自动匹配 \(plan.recoveredCount)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Label("待确认 \(plan.conflicts.count)", systemImage: "questionmark.circle")
                        Label("未找到 \(plan.unmatchedTrackIDs.count)", systemImage: "xmark.circle")
                            .foregroundStyle(
                                plan.unmatchedTrackIDs.isEmpty ? Color.secondary : Color.orange
                            )
                    }
                    .font(.caption)

                    ForEach(plan.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(URL(fileURLWithPath: conflict.expected.relativePath).lastPathComponent)
                                .font(.headline)
                            Text(conflict.expected.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("匹配文件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                AppDialogOptionMenu(
                                    selection: conflictSelectionBinding(for: conflict.expected.trackID),
                                    options: [
                                        AppDialogOption(value: "", label: "保持未连接")
                                    ] + conflict.candidates.map { candidate in
                                        AppDialogOption(
                                            value: candidate.id,
                                            label: "\(candidate.url.lastPathComponent) — \(candidate.relativePath)"
                                        )
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if case let .failed(message) = flow.operation {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ContentUnavailableView(
                    "选择候选位置",
                    systemImage: "folder.badge.plus",
                    description: Text("可一次选择多个文件夹，歌曲不会按标题或艺人匹配。")
                )
                if case let .failed(message) = flow.operation {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch target {
        case .libraryRoot:
            SettingsTaskDialogButton(
                "选择资料库",
                kind: .primary,
                disabled: flow.operation == .working
            ) { chooseLibraryRoot() }
        case .sources:
            if preparation == nil {
                SettingsTaskDialogButton(
                    "选择文件夹",
                    kind: .primary,
                    disabled: flow.operation == .working
                ) { chooseCandidateRoots() }
            } else {
                SettingsTaskDialogButton(
                    "连接来源",
                    kind: .primary,
                    disabled: flow.operation == .working || selectedPlanID.isEmpty
                ) { commitCurrentSource() }
            }
        }
    }

    private func chooseLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "连接"
        panel.begin { result in
            guard result == .OK, let url = panel.url,
                  case let .libraryRoot(libraryID, _) = target else { return }
            let access = LibraryInitialImportSelection(urls: [url])
            flow.beginOperation()
            Task {
                defer { access.release() }
                do {
                    let sourceIDs = try await appSession.reconnectRegisteredLibrary(
                        id: libraryID,
                        at: url
                    )
                    if sourceIDs.isEmpty {
                        flow.completeAndDismiss()
                    } else {
                        flow.present(.sourceReconnect(
                            libraryID: libraryID,
                            sourceIDs: sourceIDs
                        ))
                    }
                    await onChange()
                } catch LibraryOpenError.reconnectIdentifierMismatch {
                    flow.fail("所选位置属于另一资料库。")
                } catch LibraryOpenError.reconnectModeMismatch {
                    flow.fail("所选资料库的存储方式不一致。")
                } catch {
                    flow.fail("无法连接所选资料库。")
                }
            }
        }
    }

    private func chooseCandidateRoots() {
        let panel = NSOpenPanel()
        // File sources reconnect by selecting the file itself; directory
        // sources keep selecting folders.
        panel.canChooseFiles = true
        panel.allowedContentTypes = FileImportService.supportedUTTypes
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "选择"
        panel.begin { result in
            guard result == .OK, !panel.urls.isEmpty else { return }
            retainedSelection?.release()
            retainedSelection = LibraryInitialImportSelection(urls: panel.urls)
            sourceIndex = 0
            prepareCurrentSource(candidateRoots: panel.urls)
        }
    }

    private func prepareCurrentSource(candidateRoots: [URL]) {
        guard case let .sources(libraryID, sourceIDs) = target,
              appSession.activeLibraryBinding.context?.id == libraryID,
              sourceIDs.indices.contains(sourceIndex) else {
            flow.fail("当前资料库已更改。")
            return
        }
        preparation = nil
        selectedPlanID = ""
        conflictSelections = [:]
        flow.beginOperation()
        Task {
            do {
                let value = try await appSession.prepareSourceReconnect(
                    sourceID: sourceIDs[sourceIndex],
                    candidateRoots: candidateRoots
                )
                preparation = value
                selectedPlanID = value.plans.first?.id ?? ""
                flow.finishOperation()
            } catch {
                flow.fail("无法检查候选位置。")
            }
        }
    }

    private func commitCurrentSource() {
        guard let preparation,
              let plan = selectedPlan(in: preparation),
              case let .sources(libraryID, sourceIDs) = target,
              appSession.activeLibraryBinding.context?.id == libraryID else {
            flow.fail("当前资料库已更改。")
            return
        }
        let candidatesByID = Dictionary(uniqueKeysWithValues: plan.candidates.map {
            ($0.id, $0.url)
        })
        let selections = conflictSelections.reduce(into: [UUID: URL]()) { result, pair in
            guard !pair.value.isEmpty, let url = candidatesByID[pair.value] else { return }
            result[pair.key] = url
        }
        flow.beginOperation()
        Task {
            do {
                try await appSession.reconnectSource(
                    preparation: preparation,
                    planID: plan.id,
                    conflictSelections: selections
                )
                let nextIndex = sourceIndex + 1
                if sourceIDs.indices.contains(nextIndex),
                   let roots = retainedSelection?.urls {
                    sourceIndex = nextIndex
                    prepareCurrentSource(candidateRoots: roots)
                } else {
                    retainedSelection?.release()
                    retainedSelection = nil
                    flow.completeAndDismiss()
                    await onChange()
                }
            } catch {
                flow.fail("来源没有连接。")
            }
        }
    }

    private func selectedPlan(
        in preparation: SourceReconnectPreparation
    ) -> SourceReconnectPlan? {
        preparation.plans.first { $0.id == selectedPlanID }
            ?? preparation.plans.first
    }

    private func conflictSelectionBinding(for trackID: UUID) -> Binding<String> {
        Binding(
            get: { conflictSelections[trackID] ?? "" },
            set: { value in
                if value.isEmpty {
                    conflictSelections.removeValue(forKey: trackID)
                } else {
                    conflictSelections[trackID] = value
                }
            }
        )
    }

    private func cancel() {
        guard flow.operation != .working else { return }
        retainedSelection?.release()
        retainedSelection = nil
        flow.dismiss()
        onRequestClose()
    }
}
