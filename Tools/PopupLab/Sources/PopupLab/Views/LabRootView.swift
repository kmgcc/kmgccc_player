import AppKit
import PopupKit
import SwiftUI
import UniformTypeIdentifiers

struct LabRootView: View {
    @State private var model = LabModel()
    @State private var panelPresenter = LabPanelPresenter()
    @State private var sheetKind: LabSampleKind?
    @State private var showsPopover = false
    @State private var showsSystemAlert = false
    @State private var showsExport = false
    @State private var showsImport = false
    @State private var document = PresetDocument()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            workspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            LabInspector(model: model)
        }
        .frame(minWidth: 1180, minHeight: 760)
        .popupAppearance(style: PopupStyle(), palette: model.palette)
        .preferredColorScheme(model.appearance.colorScheme)
        .sheet(item: $sheetKind) { kind in
            LabSampleView(model: model, kind: kind, usesKeyboardShortcuts: true) { sheetKind = nil }
                .frame(width: kind == .options ? min(model.style.width, 360) : model.style.width)
                .fixedSize(horizontal: false, vertical: true)
                .presentationBackground(.clear)
                .presentationCornerRadius(model.style.cornerRadius)
                .interactiveDismissDisabled(!model.canDismiss(kind))
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .alert("移除此播放列表？", isPresented: $showsSystemAlert) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) { model.feedback = "系统 Alert 已确认" }
        } message: {
            Text("“雨后散步”包含 24 首歌曲，移除后歌曲仍保存在资料库中。")
        }
        .fileExporter(isPresented: $showsExport, document: document, contentType: .json, defaultFilename: "PopupStyle")
        { result in
            switch result {
            case .success: model.feedback = "已导出预设"
            case .failure: model.feedback = "预设导出失败"
            }
        }
        .fileImporter(isPresented: $showsImport, allowedContentTypes: [.json]) { result in
            importPreset(result)
        }
        .onDisappear { panelPresenter.closeForLabShutdown() }
        .onChange(of: model.sample) { _, _ in model.feedback = "" }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Popup Lab").font(.title2.weight(.semibold))
                Text("弹窗样式实验室").foregroundStyle(.secondary)
            }
            ForEach(LabSampleKind.allCases) { kind in
                Button {
                    model.sample = kind
                } label: {
                    Label(kind.title, systemImage: kind.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .foregroundStyle(model.sample == kind ? model.accent.color : model.palette.primary)
                        .background(model.accent.color.opacity(model.sample == kind ? 0.12 : 0), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.sample == kind ? .isSelected : [])
            }
            Spacer()
            Text("示例内容可自由操作。\n样式参数在右侧调整。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.sample.title).font(.title3.weight(.medium))
                Spacer()
                PopupActionGroup {
                    Button("导入预设") { showsImport = true }
                    Button("导出预设", action: exportPreset)
                    Button("复制 Swift") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.style.swiftSource, forType: .string)
                        model.feedback = "已复制样式参数"
                    }
                }
            }
            .buttonStyle(PopupButtonStyle())

            ScrollView([.horizontal, .vertical]) {
                LabSampleView(model: model, kind: model.sample, usesKeyboardShortcuts: false) {
                    if model.feedback.isEmpty { model.feedback = "已关闭演示弹窗" }
                }
                .id(model.sample)
                .frame(width: model.previewWidth)
                .padding(36)
                .frame(minWidth: 640, minHeight: 490)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                LabBackdropView(model: model)
            }

            PopupActionGroup {
                Button("打开 Sheet") { sheetKind = model.sample }
                Button("浮动面板") { panelPresenter.present(model: model, kind: model.sample) }
                Button("Popover") { showsPopover.toggle() }
                    .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                        LabSampleView(model: model, kind: .options, usesKeyboardShortcuts: true, rendersSurface: false)
                        {
                            showsPopover = false
                        }
                        .frame(width: 320)
                        .preferredColorScheme(model.appearance.colorScheme)
                    }
                Button("系统 Alert") { showsSystemAlert = true }
            }
            .buttonStyle(PopupButtonStyle())
            Text(model.feedback.isEmpty ? "画布用于调样式，下方按钮打开原生容器。" : model.feedback)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minHeight: 20, alignment: .leading)
        }
        .padding(24)
    }

    private func exportPreset() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            document = PresetDocument(data: try encoder.encode(model.preset))
            showsExport = true
        } catch {
            model.feedback = "预设导出失败"
        }
    }

    private func importPreset(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let preset = try JSONDecoder().decode(LabPreset.self, from: Data(contentsOf: url))
            guard preset.isSupported else {
                model.feedback = "预设参数超出可调范围"
                return
            }
            model.apply(preset)
            model.feedback = "已导入预设"
        } catch {
            model.feedback = "预设读取失败"
        }
    }
}
