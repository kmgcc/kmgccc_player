import PopupKit
import SwiftUI

struct LabInspector: View {
    @Bindable var model: LabModel
    @State private var showsButtonControls = true
    @State private var showsCloseControls = false
    @State private var showsScrollControls = true
    @State private var showsLayoutControls = false
    @State private var showsTextControls = false
    @State private var showsListControls = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("预设").font(.headline)
                    PopupActionGroup {
                        preset("紧凑", style: .compact)
                        preset("默认", style: PopupStyle())
                        preset("宽松", style: .spacious)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("外观").font(.headline)
                    Picker("明暗", selection: $model.appearance) {
                        ForEach(LabAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("强调色", selection: $model.accent) {
                        ForEach(LabAccent.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("材质", selection: $model.style.surface) {
                        Text("玻璃").tag(PopupStyle.Surface.glass)
                        Text("清透玻璃").tag(PopupStyle.Surface.clearGlass)
                        Text("磨砂").tag(PopupStyle.Surface.regular)
                        Text("轻磨砂").tag(PopupStyle.Surface.thin)
                        Text("实色").tag(PopupStyle.Surface.solid)
                    }
                    Picker("背景", selection: $model.backdrop) {
                        ForEach(LabBackdrop.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("内容状态").font(.headline)
                    Toggle("长文案", isOn: $model.longContent)
                    Toggle("禁用主要操作", isOn: $model.disablesPrimary)
                    if model.sample == .task {
                        Picker("任务状态", selection: $model.taskPhase) {
                            ForEach(LabTaskPhase.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        adjustment("进度", value: $model.progress, range: 0...1, step: 0.01, isPercent: true)
                    }
                }
                DisclosureGroup("按钮", isExpanded: $showsButtonControls) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("材质", selection: $model.style.buttonSurface) {
                            Text("玻璃").tag(PopupStyle.ButtonSurface.glass)
                            Text("清透玻璃").tag(PopupStyle.ButtonSurface.clearGlass)
                            Text("实色").tag(PopupStyle.ButtonSurface.solid)
                        }
                        adjustment("最小高度", value: $model.style.buttonHeight, range: 28...40)
                        adjustment("字号", value: $model.style.buttonFontSize, range: 11...16)
                        Picker("对齐", selection: $model.style.actionAlignment) {
                            Text("靠左").tag(PopupStyle.ActionAlignment.leading)
                            Text("居中").tag(PopupStyle.ActionAlignment.center)
                            Text("靠右").tag(PopupStyle.ActionAlignment.trailing)
                        }
                        adjustment("上外边距", value: $model.style.buttonMarginTop, range: 0...80)
                        adjustment("下外边距", value: $model.style.buttonMarginBottom, range: 0...80)
                        adjustment("左外边距", value: $model.style.buttonMarginLeading, range: 0...80)
                        adjustment("右外边距", value: $model.style.buttonMarginTrailing, range: 0...80)
                        adjustment("最小宽度", value: $model.style.buttonMinWidth, range: 44...100)
                        adjustment("按钮间距", value: $model.style.buttonSpacing, range: 4...20)
                    }.padding(.top, 10)
                }
                DisclosureGroup("右上角关闭按钮", isExpanded: $showsCloseControls) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("显示关闭按钮", isOn: $model.style.showsCloseButton)
                        adjustment("最小尺寸", value: $model.style.closeButtonSize, range: 24...44)
                        adjustment("关闭图标大小", value: $model.style.closeIconSize, range: 8...18)
                        adjustment("距上边缘", value: $model.style.closeMarginTop, range: 0...80)
                        adjustment("距右边缘", value: $model.style.closeMarginTrailing, range: 0...80)
                    }.padding(.top, 10)
                }
                DisclosureGroup("滚动与操作区", isExpanded: $showsScrollControls) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("悬浮按钮", isOn: $model.style.floatsFooter)
                        adjustment("边缘淡出", value: $model.style.edgeFadeLength, range: 0...60)
                        adjustment("遮罩范围", value: $model.style.actionHaloRadius, range: 4...40)
                        adjustment(
                            "最低不透明度", value: $model.style.actionHaloMinOpacity, range: 0.2...0.85, step: 0.01,
                            isPercent: true)
                        adjustment("阅读区高度", value: $model.style.readerHeight, range: 180...420)
                        adjustment("列表区高度", value: $model.style.taskListHeight, range: 160...360)
                    }.padding(.top, 10)
                }
                DisclosureGroup("布局", isExpanded: $showsLayoutControls) {
                    VStack(alignment: .leading, spacing: 14) {
                        adjustment("宽度", value: $model.style.width, range: 400...640)
                        adjustment("圆角", value: $model.style.cornerRadius, range: 8...32)
                        adjustment("内边距", value: $model.style.padding, range: 16...32)
                        adjustment("区域间距", value: $model.style.sectionSpacing, range: 12...28)
                        Toggle("分隔线", isOn: $model.style.showsSeparators)
                    }.padding(.top, 10)
                }
                DisclosureGroup("文字与标题", isExpanded: $showsTextControls) {
                    VStack(alignment: .leading, spacing: 14) {
                        adjustment("标题字号", value: $model.style.titleSize, range: 16...22)
                        adjustment("正文字号", value: $model.style.bodySize, range: 12...16)
                        adjustment("正文行距", value: $model.style.bodyLineSpacing, range: 0...12)
                        adjustment("标题间距", value: $model.style.titleBodySpacing, range: 2...12)
                        adjustment("图文间距", value: $model.style.headerSpacing, range: 6...20)
                        adjustment("图标大小", value: $model.style.iconSize, range: 14...26)
                        Toggle("标题图标", isOn: $model.style.showsIcon)
                    }.padding(.top, 10)
                }
                DisclosureGroup("列表", isExpanded: $showsListControls) {
                    VStack(alignment: .leading, spacing: 14) {
                        adjustment("行间距", value: $model.style.rowSpacing, range: 4...20)
                        adjustment("行内留白", value: $model.style.rowPadding, range: 8...20)
                    }.padding(.top, 10)
                }
            }
            .toggleStyle(.switch)
            .padding(20)
        }
        .frame(width: 270)
    }

    private func preset(_ title: String, style: PopupStyle) -> some View {
        Button(title) { model.style = style }
            .buttonStyle(PopupButtonStyle())
    }

    private func adjustment(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        isPercent: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(isPercent ? "\(Int(value.wrappedValue * 100))%" : "\(Int(value.wrappedValue))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
        }
    }
}
