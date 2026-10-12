import Observation
import PopupKit
import SwiftUI

enum LabSampleKind: String, CaseIterable, Identifiable {
    case confirmation, form, task, reader, options
    var id: Self { self }

    var title: String {
        switch self {
        case .confirmation: "短确认"
        case .form: "编辑表单"
        case .task: "任务进度"
        case .reader: "阅读面板"
        case .options: "轻量选择"
        }
    }

    var symbol: String {
        switch self {
        case .confirmation: "exclamationmark.circle"
        case .form: "square.and.pencil"
        case .task: "arrow.down.circle"
        case .reader: "text.alignleft"
        case .options: "list.bullet"
        }
    }
}

enum LabAppearance: String, Codable, CaseIterable {
    case system, light, dark
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum LabAccent: String, Codable, CaseIterable {
    case indigo, teal, rust
    var title: String {
        switch self {
        case .indigo: "靛蓝"
        case .teal: "青绿"
        case .rust: "赭红"
        }
    }
    // Lab-only colors. Production supplies the active ThemeStore semantic palette.
    var color: Color {
        switch self {
        case .indigo: Color(red: 0.32, green: 0.35, blue: 0.72)
        case .teal: Color(red: 0.12, green: 0.43, blue: 0.42)
        case .rust: Color(red: 0.65, green: 0.28, blue: 0.20)
        }
    }
}

enum LabTaskPhase: String, CaseIterable {
    case running, cancelling, finished, failed
    var title: String {
        switch self {
        case .running: "进行中"
        case .cancelling: "取消中"
        case .finished: "已完成"
        case .failed: "失败"
        }
    }
    var canDismiss: Bool { self == .finished || self == .failed }
}

enum LabBackdrop: String, CaseIterable {
    case plain, color, contrast
    var title: String {
        switch self {
        case .plain: "素色"
        case .color: "色彩"
        case .contrast: "明暗"
        }
    }
}

struct LabPreset: Codable {
    var version = 3
    var style: PopupStyle
    var appearance: LabAppearance
    var accent: LabAccent

    /// Imported files must stay within the same supported layout ranges as the inspector.
    var isSupported: Bool {
        (1...3).contains(version)
            && (400...640).contains(style.width)
            && (8...32).contains(style.cornerRadius)
            && (16...32).contains(style.padding)
            && (12...28).contains(style.sectionSpacing)
            && (16...22).contains(style.titleSize)
            && (12...16).contains(style.bodySize)
            && (28...40).contains(style.buttonHeight)
            && (11...16).contains(style.buttonFontSize)
            && (8...24).contains(style.buttonHorizontalPadding)
            && (0...80).contains(style.buttonMarginTop)
            && (0...80).contains(style.buttonMarginBottom)
            && (0...80).contains(style.buttonMarginLeading)
            && (0...80).contains(style.buttonMarginTrailing)
            && (44...100).contains(style.buttonMinWidth)
            && (4...20).contains(style.buttonSpacing)
            && (24...44).contains(style.closeButtonSize)
            && (8...18).contains(style.closeIconSize)
            && (0...80).contains(style.closeMarginTop)
            && (0...80).contains(style.closeMarginTrailing)
            && (6...20).contains(style.headerSpacing)
            && (2...12).contains(style.titleBodySpacing)
            && (14...26).contains(style.iconSize)
            && (0...12).contains(style.bodyLineSpacing)
            && (4...20).contains(style.rowSpacing)
            && (8...20).contains(style.rowPadding)
            && (180...420).contains(style.readerHeight)
            && (160...360).contains(style.taskListHeight)
            && (0...60).contains(style.edgeFadeLength)
            && (4...40).contains(style.actionHaloRadius)
            && (0.2...0.85).contains(style.actionHaloMinOpacity)
    }
}

@MainActor @Observable
final class LabModel {
    var sample: LabSampleKind = .reader
    var style = PopupStyle()
    var appearance: LabAppearance = .system
    var accent: LabAccent = .indigo
    var backdrop: LabBackdrop = .color
    var longContent = true
    var disablesPrimary = false
    var taskPhase: LabTaskPhase = .running
    var progress = 0.42
    var feedback = ""

    var palette: PopupPalette { PopupPalette(accent: accent.color) }
    var previewWidth: Double { sample == .options ? min(style.width, 360) : style.width }

    func canDismiss(_ sample: LabSampleKind) -> Bool {
        sample != .task || taskPhase.canDismiss
    }

    var preset: LabPreset { LabPreset(style: style, appearance: appearance, accent: accent) }

    func apply(_ preset: LabPreset) {
        style = preset.style
        appearance = preset.appearance
        accent = preset.accent
    }
}
