import PopupKit
import SwiftUI

/// Fictional content only. Every host instantiates this exact view and PopupKit renderer.
struct LabSampleView: View {
    @Bindable var model: LabModel
    let kind: LabSampleKind
    let usesKeyboardShortcuts: Bool
    var rendersSurface = true
    let onClose: () -> Void

    @State private var name = "雨后散步"
    @State private var keepsArtwork = true
    @State private var selectedOption = "原位引用"
    private var floatsActions: Bool {
        model.style.floatsFooter && (kind == .reader || kind == .task)
    }

    private var title: String {
        switch kind {
        case .confirmation:
            model.longContent ? "移除“雨后散步 · 城市里的漫长夜晚与那些尚未听完的歌”？" : "移除此播放列表？"
        case .form: "新建播放列表"
        case .task:
            switch model.taskPhase {
            case .running: "正在导入歌曲"
            case .cancelling: "正在取消导入"
            case .finished: "导入完成"
            case .failed: "导入未完成"
            }
        case .reader: "专辑介绍"
        case .options: "导入方式"
        }
    }

    var body: some View {
        PopupFrame(
            title: title,
            systemImage: kind.symbol,
            onClose: model.canDismiss(kind) ? onClose : nil,
            showsFooter: !floatsActions,
            rendersSurface: rendersSurface
        ) {
            content
        } footer: {
            footer
        }
        .popupAppearance(style: model.style, palette: model.palette)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .confirmation:
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    model.longContent
                        ? "“雨后散步 · 城市里的漫长夜晚与那些尚未听完的歌”包含 128 首歌曲。移除后，播放列表中的排序和说明将被删除，歌曲仍保存在资料库中。"
                        : "“雨后散步”包含 24 首歌曲，移除后歌曲仍保存在资料库中。"
                )
                .foregroundStyle(model.palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .form:
            VStack(alignment: .leading, spacing: 16) {
                TextField("名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("播放列表名称")
                Toggle("使用歌曲封面", isOn: $keepsArtwork)
                    .toggleStyle(.switch)
                if model.longContent {
                    Text("播放列表名称可以包含中文、英文和标点。此处用于检查较长说明在窄窗口中的换行与按钮间距。")
                        .foregroundStyle(model.palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .task:
            LabTaskContent(model: model) { footer }
        case .reader:
            PopupScrollRegion(height: model.style.readerHeight) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<(model.longContent ? 12 : 3), id: \.self) { index in
                        Text(
                            index.isMultiple(of: 2)
                                ? "雨停之后，街道恢复了安静。唱片里的几段钢琴与远处的脚步声交织，留下一个缓慢而清晰的夜晚。"
                                : "这些歌曲收录于不同的季节，沿着相近的节奏排列。它们适合在散步时听，也适合留在一盏灯下。"
                        )
                        .lineSpacing(model.style.bodyLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } actions: {
                footer
            }
        case .options:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["原位引用", "复制到资料库"], id: \.self) { option in
                    Button {
                        selectedOption = option
                    } label: {
                        HStack {
                            Text(option)
                            Spacer()
                            if selectedOption == option { Image(systemName: "checkmark") }
                        }
                        .padding(12)
                        .foregroundStyle(model.palette.primary)
                        .background(
                            model.palette.accent.opacity(selectedOption == option ? 0.12 : 0.03),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedOption == option ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch kind {
        case .confirmation:
            PopupActionGroup {
                cancelButton
                PopupAction("移除", kind: .destructive) { finish("已移除演示播放列表") }
                    .disabled(model.disablesPrimary)
            }
        case .form:
            PopupActionGroup {
                cancelButton
                PopupAction("创建", kind: .primary, shortcut: defaultShortcut) { finish("已创建演示播放列表") }
                    .disabled(model.disablesPrimary || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .task:
            if model.taskPhase.canDismiss {
                PopupAction("关闭", shortcut: cancelShortcut, action: onClose)
            } else {
                PopupAction(model.taskPhase == .cancelling ? "取消中" : "取消导入") {
                    model.taskPhase = .cancelling
                    model.feedback = "取消中；可在右侧切换完成状态"
                }
                .disabled(model.taskPhase == .cancelling || model.disablesPrimary)
            }
        case .reader:
            PopupAction("关闭", shortcut: cancelShortcut, action: onClose)
        case .options:
            PopupAction("完成", kind: .primary, shortcut: defaultShortcut) { finish("已选择“\(selectedOption)”") }
                .disabled(model.disablesPrimary)
        }
    }

    private var cancelButton: some View {
        PopupAction("取消", shortcut: cancelShortcut) {
            model.feedback = "已取消演示操作"
            onClose()
        }
    }
    private var defaultShortcut: KeyboardShortcut? { usesKeyboardShortcuts ? .defaultAction : nil }
    private var cancelShortcut: KeyboardShortcut? { usesKeyboardShortcuts ? .cancelAction : nil }

    private func finish(_ message: String) {
        model.feedback = message
        onClose()
    }
}

private struct LabTaskContent<Actions: View>: View {
    @Bindable var model: LabModel
    private let actions: Actions
    private var value: Double { model.taskPhase == .finished ? 1 : model.progress }

    init(model: LabModel, @ViewBuilder actions: () -> Actions) {
        self.model = model
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: value)
                .accessibilityLabel("导入进度")
            HStack {
                Text(model.taskPhase.title)
                Spacer()
                Text("\(Int(value * 24)) / 24")
                    .monospacedDigit()
            }
            .foregroundStyle(model.palette.secondary)
            PopupScrollRegion(height: model.style.taskListHeight) {
                VStack(spacing: model.style.rowSpacing) {
                    ForEach(0..<(model.longContent ? 15 : 4), id: \.self) { index in
                        HStack(spacing: 12) {
                            Image(
                                systemName: index == 2 && model.taskPhase == .failed
                                    ? "exclamationmark.circle" : "music.note"
                            )
                            .foregroundStyle(
                                index == 2 && model.taskPhase == .failed
                                    ? model.palette.danger : model.palette.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.longContent ? "一首很长的歌名：穿过雨后的街道，回到灯光亮起的地方 \(index + 1)" : "夜间散步 \(index + 1)")
                                    .lineLimit(2)
                                Text(index == 2 && model.taskPhase == .failed ? "文件读取失败" : "钢琴 · 04:12")
                                    .font(.caption)
                                    .foregroundStyle(model.palette.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(model.style.rowPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.palette.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            } actions: {
                actions
            }
        }
    }
}
