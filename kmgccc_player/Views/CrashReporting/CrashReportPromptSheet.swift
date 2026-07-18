import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CrashReportPromptSheet: View {
    let onCancel: () -> Void
    let onExport: (String) async throws -> CrashReportExportPayload
    let onSend: (String) -> Void

    @State private var description = ""
    @State private var exportDocument: CrashReportExportDocument?
    @State private var exportFilename = "crash-report.json"
    @State private var isPreparingExport = false
    @State private var isExporting = false
    @State private var exportErrorMessage: String?
    @FocusState private var descriptionIsFocused: Bool

    private let characterLimit = 1_000

    var body: some View {
        VStack(spacing: 0) {
            AppDialogConfirmHeader(
                iconName: "exclamationmark.triangle.fill",
                iconColor: .orange,
                title: "检测到 App 上次意外退出"
            )

            AppDialogDivider()

            VStack(alignment: .leading, spacing: 10) {
                Text("崩溃前你正在进行什么操作？")
                    .font(.headline)

                Text("如果不记得，可以留空。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $description)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .focused($descriptionIsFocused)
                        .padding(6)

                    if description.isEmpty {
                        Text("例如：正在切换歌曲、导入音乐或进入全屏播放……")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 118)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator.opacity(0.55), lineWidth: 0.5)
                )
                .accessibilityLabel("崩溃前的操作说明")

                HStack {
                    Text("最多 \(characterLimit) 个字符")
                    Spacer()
                    Text("\(description.count) / \(characterLimit)")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)

            AppDialogDivider()

            HStack(spacing: 10) {
                Button("保存报告…") {
                    prepareExport()
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .disabled(isPreparingExport)

                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .keyboardShortcut(.cancelAction)

                Button("发送") {
                    onSend(description)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
                .keyboardShortcut(.return, modifiers: .command)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 520)
        .interactiveDismissDisabled()
        .onAppear {
            descriptionIsFocused = true
        }
        .onChange(of: description) { _, newValue in
            if newValue.count > characterLimit {
                description = String(newValue.prefix(characterLimit))
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            if case .failure(let error) = result {
                let cocoaError = error as NSError
                if cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError {
                    exportErrorMessage = error.localizedDescription
                }
            }
        }
        .alert("无法保存崩溃报告", isPresented: exportErrorIsPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "请稍后再试。")
        }
    }

    private var exportErrorIsPresented: Binding<Bool> {
        Binding(
            get: { exportErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    exportErrorMessage = nil
                }
            }
        )
    }

    private func prepareExport() {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        Task {
            defer { isPreparingExport = false }
            do {
                let payload = try await onExport(description)
                exportDocument = CrashReportExportDocument(data: payload.data)
                exportFilename = payload.suggestedFilename
                isExporting = true
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct CrashReportExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
