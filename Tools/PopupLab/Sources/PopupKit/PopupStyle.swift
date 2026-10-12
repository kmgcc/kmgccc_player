import Foundation

/// Value-only appearance settings; presentation and business state belong to the caller.
public struct PopupStyle: Codable, Equatable, Sendable {
    public enum Surface: String, Codable, CaseIterable, Sendable {
        case glass, clearGlass, solid, regular, thin
    }
    public enum ButtonSurface: String, Codable, CaseIterable, Sendable {
        case glass, clearGlass, solid
    }
    public enum ActionAlignment: String, Codable, CaseIterable, Sendable {
        case leading, center, trailing
    }

    // Standard values match the style selected in Popup Lab.
    public var width: Double = 510
    public var cornerRadius: Double = 15
    public var padding: Double = 24
    public var sectionSpacing: Double = 16
    public var titleSize: Double = 18
    public var bodySize: Double = 14
    public var buttonHeight: Double = 32
    public var buttonFontSize: Double = 14
    public var buttonHorizontalPadding: Double = 12
    public var buttonMarginTop: Double = 13
    public var buttonMarginBottom: Double = 13
    public var buttonMarginLeading: Double = 14
    public var buttonMarginTrailing: Double = 14
    public var actionAlignment: ActionAlignment = .trailing
    public var buttonMinWidth: Double = 63
    public var buttonSpacing: Double = 7
    public var buttonSurface: ButtonSurface = .glass
    public var closeButtonSize: Double = 32
    public var closeIconSize: Double = 13
    public var closeMarginTop: Double = 13
    public var closeMarginTrailing: Double = 14
    public var showsCloseButton: Bool = true
    public var headerSpacing: Double = 18
    public var titleBodySpacing: Double = 6
    public var iconSize: Double = 20
    public var bodyLineSpacing: Double = 6
    public var rowSpacing: Double = 6
    public var rowPadding: Double = 10
    public var readerHeight: Double = 384
    public var taskListHeight: Double = 360
    public var edgeFadeLength: Double = 9
    public var floatsFooter: Bool = true
    public var actionHaloRadius: Double = 8
    public var actionHaloMinOpacity: Double = 0.36
    public var showsSeparators: Bool = false
    public var showsIcon: Bool = true
    public var surface: Surface = .glass

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case width
        case cornerRadius
        case padding
        case sectionSpacing
        case titleSize
        case bodySize
        case buttonHeight
        case buttonFontSize
        case buttonHorizontalPadding
        case buttonMarginTop
        case buttonMarginBottom
        case buttonMarginLeading
        case buttonMarginTrailing
        case actionAlignment
        case buttonMinWidth
        case buttonSpacing
        case buttonSurface
        case closeButtonSize
        case closeIconSize
        case closeMarginTop
        case closeMarginTrailing
        case showsCloseButton
        case headerSpacing
        case titleBodySpacing
        case iconSize
        case bodyLineSpacing
        case rowSpacing
        case rowPadding
        case readerHeight
        case taskListHeight
        case edgeFadeLength
        case floatsFooter
        case actionHaloRadius
        case actionHaloMinOpacity
        case showsSeparators
        case showsIcon
        case surface
        case floatingActionInset
    }

    /// Version 1/2 presets derive outer action margins from their content inset.
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        width = try values.decodeIfPresent(Double.self, forKey: .width) ?? width
        cornerRadius = try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? cornerRadius
        padding = try values.decodeIfPresent(Double.self, forKey: .padding) ?? padding
        sectionSpacing = try values.decodeIfPresent(Double.self, forKey: .sectionSpacing) ?? sectionSpacing
        titleSize = try values.decodeIfPresent(Double.self, forKey: .titleSize) ?? titleSize
        bodySize = try values.decodeIfPresent(Double.self, forKey: .bodySize) ?? bodySize
        buttonHeight = try values.decodeIfPresent(Double.self, forKey: .buttonHeight) ?? buttonHeight
        buttonFontSize = try values.decodeIfPresent(Double.self, forKey: .buttonFontSize) ?? buttonFontSize
        buttonHorizontalPadding =
            try values.decodeIfPresent(Double.self, forKey: .buttonHorizontalPadding) ?? buttonHorizontalPadding
        actionAlignment = try values.decodeIfPresent(ActionAlignment.self, forKey: .actionAlignment) ?? actionAlignment
        buttonMinWidth = try values.decodeIfPresent(Double.self, forKey: .buttonMinWidth) ?? buttonMinWidth
        buttonSpacing = try values.decodeIfPresent(Double.self, forKey: .buttonSpacing) ?? buttonSpacing
        buttonSurface = try values.decodeIfPresent(ButtonSurface.self, forKey: .buttonSurface) ?? buttonSurface
        closeButtonSize = try values.decodeIfPresent(Double.self, forKey: .closeButtonSize) ?? closeButtonSize
        closeIconSize = try values.decodeIfPresent(Double.self, forKey: .closeIconSize) ?? closeIconSize
        showsCloseButton = try values.decodeIfPresent(Bool.self, forKey: .showsCloseButton) ?? showsCloseButton
        headerSpacing = try values.decodeIfPresent(Double.self, forKey: .headerSpacing) ?? headerSpacing
        titleBodySpacing = try values.decodeIfPresent(Double.self, forKey: .titleBodySpacing) ?? titleBodySpacing
        iconSize = try values.decodeIfPresent(Double.self, forKey: .iconSize) ?? iconSize
        bodyLineSpacing = try values.decodeIfPresent(Double.self, forKey: .bodyLineSpacing) ?? bodyLineSpacing
        rowSpacing = try values.decodeIfPresent(Double.self, forKey: .rowSpacing) ?? rowSpacing
        rowPadding = try values.decodeIfPresent(Double.self, forKey: .rowPadding) ?? rowPadding
        readerHeight = try values.decodeIfPresent(Double.self, forKey: .readerHeight) ?? readerHeight
        taskListHeight = try values.decodeIfPresent(Double.self, forKey: .taskListHeight) ?? taskListHeight
        edgeFadeLength = try values.decodeIfPresent(Double.self, forKey: .edgeFadeLength) ?? edgeFadeLength
        floatsFooter = try values.decodeIfPresent(Bool.self, forKey: .floatsFooter) ?? floatsFooter
        actionHaloRadius = try values.decodeIfPresent(Double.self, forKey: .actionHaloRadius) ?? actionHaloRadius
        actionHaloMinOpacity =
            try values.decodeIfPresent(Double.self, forKey: .actionHaloMinOpacity) ?? actionHaloMinOpacity
        showsSeparators = try values.decodeIfPresent(Bool.self, forKey: .showsSeparators) ?? showsSeparators
        showsIcon = try values.decodeIfPresent(Bool.self, forKey: .showsIcon) ?? showsIcon
        surface = try values.decodeIfPresent(Surface.self, forKey: .surface) ?? surface
        let oldInset = try values.decodeIfPresent(Double.self, forKey: .floatingActionInset) ?? 0
        buttonMarginTop = try values.decodeIfPresent(Double.self, forKey: .buttonMarginTop) ?? sectionSpacing
        buttonMarginBottom = try values.decodeIfPresent(Double.self, forKey: .buttonMarginBottom) ?? padding + oldInset
        buttonMarginLeading =
            try values.decodeIfPresent(Double.self, forKey: .buttonMarginLeading) ?? padding + oldInset
        buttonMarginTrailing =
            try values.decodeIfPresent(Double.self, forKey: .buttonMarginTrailing) ?? padding + oldInset
        closeMarginTop = try values.decodeIfPresent(Double.self, forKey: .closeMarginTop) ?? padding
        closeMarginTrailing = try values.decodeIfPresent(Double.self, forKey: .closeMarginTrailing) ?? padding
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(width, forKey: .width)
        try values.encode(cornerRadius, forKey: .cornerRadius)
        try values.encode(padding, forKey: .padding)
        try values.encode(sectionSpacing, forKey: .sectionSpacing)
        try values.encode(titleSize, forKey: .titleSize)
        try values.encode(bodySize, forKey: .bodySize)
        try values.encode(buttonHeight, forKey: .buttonHeight)
        try values.encode(buttonFontSize, forKey: .buttonFontSize)
        try values.encode(buttonHorizontalPadding, forKey: .buttonHorizontalPadding)
        try values.encode(buttonMarginTop, forKey: .buttonMarginTop)
        try values.encode(buttonMarginBottom, forKey: .buttonMarginBottom)
        try values.encode(buttonMarginLeading, forKey: .buttonMarginLeading)
        try values.encode(buttonMarginTrailing, forKey: .buttonMarginTrailing)
        try values.encode(actionAlignment, forKey: .actionAlignment)
        try values.encode(buttonMinWidth, forKey: .buttonMinWidth)
        try values.encode(buttonSpacing, forKey: .buttonSpacing)
        try values.encode(buttonSurface, forKey: .buttonSurface)
        try values.encode(closeButtonSize, forKey: .closeButtonSize)
        try values.encode(closeIconSize, forKey: .closeIconSize)
        try values.encode(closeMarginTop, forKey: .closeMarginTop)
        try values.encode(closeMarginTrailing, forKey: .closeMarginTrailing)
        try values.encode(showsCloseButton, forKey: .showsCloseButton)
        try values.encode(headerSpacing, forKey: .headerSpacing)
        try values.encode(titleBodySpacing, forKey: .titleBodySpacing)
        try values.encode(iconSize, forKey: .iconSize)
        try values.encode(bodyLineSpacing, forKey: .bodyLineSpacing)
        try values.encode(rowSpacing, forKey: .rowSpacing)
        try values.encode(rowPadding, forKey: .rowPadding)
        try values.encode(readerHeight, forKey: .readerHeight)
        try values.encode(taskListHeight, forKey: .taskListHeight)
        try values.encode(edgeFadeLength, forKey: .edgeFadeLength)
        try values.encode(floatsFooter, forKey: .floatsFooter)
        try values.encode(actionHaloRadius, forKey: .actionHaloRadius)
        try values.encode(actionHaloMinOpacity, forKey: .actionHaloMinOpacity)
        try values.encode(showsSeparators, forKey: .showsSeparators)
        try values.encode(showsIcon, forKey: .showsIcon)
        try values.encode(surface, forKey: .surface)
    }

    /// Scales layout lengths for fullscreen surfaces while preserving semantic choices.
    public func scaled(by factor: Double) -> Self {
        var style = self
        style.width *= factor
        style.cornerRadius *= factor
        style.padding *= factor
        style.sectionSpacing *= factor
        style.titleSize *= factor
        style.bodySize *= factor
        style.buttonHeight *= factor
        style.buttonFontSize *= factor
        style.buttonHorizontalPadding *= factor
        style.buttonMarginTop *= factor
        style.buttonMarginBottom *= factor
        style.buttonMarginLeading *= factor
        style.buttonMarginTrailing *= factor
        style.buttonMinWidth *= factor
        style.buttonSpacing *= factor
        style.closeButtonSize *= factor
        style.closeIconSize *= factor
        style.closeMarginTop *= factor
        style.closeMarginTrailing *= factor
        style.headerSpacing *= factor
        style.titleBodySpacing *= factor
        style.iconSize *= factor
        style.bodyLineSpacing *= factor
        style.rowSpacing *= factor
        style.rowPadding *= factor
        style.readerHeight *= factor
        style.taskListHeight *= factor
        style.edgeFadeLength *= factor
        style.actionHaloRadius *= factor
        return style
    }

    public static var compact: Self {
        var style = Self()
        style.width = 440
        style.cornerRadius = 16
        style.padding = 20
        style.sectionSpacing = 16
        style.titleSize = 17
        style.buttonHeight = 30
        style.readerHeight = 280
        style.taskListHeight = 220
        style.buttonMarginTop = style.sectionSpacing
        style.buttonMarginBottom = style.padding
        style.buttonMarginLeading = style.padding
        style.buttonMarginTrailing = style.padding
        style.closeMarginTop = style.padding
        style.closeMarginTrailing = style.padding
        return style
    }

    public static var spacious: Self {
        var style = Self()
        style.width = 600
        style.padding = 28
        style.sectionSpacing = 24
        style.titleSize = 20
        style.buttonHeight = 36
        style.readerHeight = 360
        style.taskListHeight = 300
        style.buttonMarginTop = style.sectionSpacing
        style.buttonMarginBottom = style.padding
        style.buttonMarginLeading = style.padding
        style.buttonMarginTrailing = style.padding
        style.closeMarginTop = style.padding
        style.closeMarginTrailing = style.padding
        return style
    }

    /// A pasteable preset for the same renderer used in the lab and in the app.
    public var swiftSource: String {
        """
        import PopupKit

        var popupStyle = PopupStyle()
        popupStyle.width = \(width)
        popupStyle.cornerRadius = \(cornerRadius)
        popupStyle.padding = \(padding)
        popupStyle.sectionSpacing = \(sectionSpacing)
        popupStyle.titleSize = \(titleSize)
        popupStyle.bodySize = \(bodySize)
        popupStyle.buttonHeight = \(buttonHeight)
        popupStyle.buttonFontSize = \(buttonFontSize)
        popupStyle.buttonHorizontalPadding = \(buttonHorizontalPadding)
        popupStyle.buttonMarginTop = \(buttonMarginTop)
        popupStyle.buttonMarginBottom = \(buttonMarginBottom)
        popupStyle.buttonMarginLeading = \(buttonMarginLeading)
        popupStyle.buttonMarginTrailing = \(buttonMarginTrailing)
        popupStyle.actionAlignment = .\(actionAlignment.rawValue)
        popupStyle.buttonMinWidth = \(buttonMinWidth)
        popupStyle.buttonSpacing = \(buttonSpacing)
        popupStyle.buttonSurface = .\(buttonSurface.rawValue)
        popupStyle.closeButtonSize = \(closeButtonSize)
        popupStyle.closeIconSize = \(closeIconSize)
        popupStyle.closeMarginTop = \(closeMarginTop)
        popupStyle.closeMarginTrailing = \(closeMarginTrailing)
        popupStyle.showsCloseButton = \(showsCloseButton)
        popupStyle.headerSpacing = \(headerSpacing)
        popupStyle.titleBodySpacing = \(titleBodySpacing)
        popupStyle.iconSize = \(iconSize)
        popupStyle.bodyLineSpacing = \(bodyLineSpacing)
        popupStyle.rowSpacing = \(rowSpacing)
        popupStyle.rowPadding = \(rowPadding)
        popupStyle.readerHeight = \(readerHeight)
        popupStyle.taskListHeight = \(taskListHeight)
        popupStyle.edgeFadeLength = \(edgeFadeLength)
        popupStyle.floatsFooter = \(floatsFooter)
        popupStyle.actionHaloRadius = \(actionHaloRadius)
        popupStyle.actionHaloMinOpacity = \(actionHaloMinOpacity)
        popupStyle.showsSeparators = \(showsSeparators)
        popupStyle.showsIcon = \(showsIcon)
        popupStyle.surface = .\(surface.rawValue)
        """
    }
}
