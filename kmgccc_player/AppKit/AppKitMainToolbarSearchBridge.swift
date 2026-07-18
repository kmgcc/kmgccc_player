//
//  AppKitMainToolbarSearchBridge.swift
//  myPlayer2
//
//  Target-action and delegate bridge for the main toolbar search controls.
//

import AppKit

@MainActor
protocol AppKitMainToolbarSearchBridgeDelegate: AnyObject {
    func toolbarSearchBridge(
        _ bridge: AppKitMainToolbarSearchBridge,
        didChangeText text: String,
        generation: Int
    )

    func toolbarSearchBridgeDidBeginEditing(
        _ bridge: AppKitMainToolbarSearchBridge,
        generation: Int
    )

    func toolbarSearchBridge(
        _ bridge: AppKitMainToolbarSearchBridge,
        didSelectHistoryRange range: PlaybackHistorySearchRange,
        generation: Int
    )
}

@MainActor
final class AppKitMainToolbarSearchBridge: NSObject, NSSearchFieldDelegate {
    private final class HistoryRangePayload: NSObject {
        let range: PlaybackHistorySearchRange
        let generation: Int

        init(range: PlaybackHistorySearchRange, generation: Int) {
            self.range = range
            self.generation = generation
        }
    }

    // The main toolbar controller owns this helper. AppKit controls target it,
    // and the weak delegate prevents the bridge from retaining the controller.
    weak var delegate: AppKitMainToolbarSearchBridgeDelegate?

    private weak var searchItem: NSToolbarItem?
    private weak var searchField: NSSearchField?
    private weak var historySearchRangeButton: NSPopUpButton?

    var currentText: String? {
        searchField?.stringValue
    }

    func makeToolbarItem(
        isHistoryMode: Bool,
        generation: Int
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: AppKitMainToolbarController.Identifier.search)
        item.label = NSLocalizedString("library.search", comment: "Search")
        item.paletteLabel = item.label
        item.toolTip = item.label

        let width: CGFloat = isHistoryMode ? 216 : 176
        let height: CGFloat = 28
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setContentHuggingPriority(.required, for: .horizontal)
        container.setContentCompressionResistancePriority(.required, for: .horizontal)

        let field = NSSearchField(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "在播放列表中搜索"
        field.sendsSearchStringImmediately = true
        container.addSubview(field)

        var constraints = [
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: width),
            container.heightAnchor.constraint(equalToConstant: height)
        ]

        if isHistoryMode {
            let rangeButton = makeHistorySearchRangeButton(generation: generation)
            container.addSubview(rangeButton)
            NSLayoutConstraint.activate([
                rangeButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                rangeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                rangeButton.widthAnchor.constraint(equalToConstant: 30),
                rangeButton.heightAnchor.constraint(equalToConstant: height)
            ])
            constraints.append(field.leadingAnchor.constraint(equalTo: rangeButton.trailingAnchor, constant: 2))
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: container.leadingAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        item.view = container
        attach(to: item, generation: generation)
        return item
    }

    func attach(to item: NSToolbarItem, generation: Int) {
        guard item.itemIdentifier == AppKitMainToolbarController.Identifier.search else { return }
        resetReferences()
        searchItem = item

        if let itemView = item.view,
           let field = firstSubview(in: itemView, matching: { $0 is NSSearchField }) as? NSSearchField {
            field.tag = generation
            field.target = self
            field.action = #selector(handleSearchChange(_:))
            field.delegate = self
            searchField = field
        }

        if let itemView = item.view,
           let rangeButton = firstSubview(in: itemView, matching: { $0 is NSPopUpButton }) as? NSPopUpButton {
            rangeButton.tag = generation
            rangeButton.target = self
            rangeButton.action = #selector(handleHistorySearchRange(_:))
            configureHistoryRangeMenu(rangeButton.menu, generation: generation)
            historySearchRangeButton = rangeButton
        }
    }

    func detachControls(in item: NSToolbarItem) {
        guard item.itemIdentifier == AppKitMainToolbarController.Identifier.search else { return }
        if let itemView = item.view,
           let field = firstSubview(in: itemView, matching: { $0 is NSSearchField }) as? NSSearchField {
            if field.target === self {
                field.target = nil
                field.action = nil
            }
            if field.delegate === self {
                field.delegate = nil
            }
        }
        if let itemView = item.view,
           let rangeButton = firstSubview(in: itemView, matching: { $0 is NSPopUpButton }) as? NSPopUpButton {
            if rangeButton.target === self {
                rangeButton.target = nil
                rangeButton.action = nil
            }
            rangeButton.menu?.items.forEach { menuItem in
                if menuItem.target === self {
                    menuItem.target = nil
                    menuItem.action = nil
                }
            }
        }
        if searchItem === item {
            resetReferences()
        }
    }

    func resetReferences() {
        searchItem = nil
        searchField = nil
        historySearchRangeButton = nil
    }

    func sync(
        text: String,
        placeholder: String,
        historyRange: PlaybackHistorySearchRange?
    ) {
        guard searchItem != nil, let searchField else { return }
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        searchField.placeholderString = placeholder
        if let historyRange {
            syncHistoryRangePresentation(historyRange)
        }
    }

    func syncPlaceholder(_ placeholder: String) {
        searchField?.placeholderString = placeholder
    }

    func syncHistoryRangePresentation(_ range: PlaybackHistorySearchRange) {
        guard let button = historySearchRangeButton else { return }
        button.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease.circle",
            accessibilityDescription: "搜索范围：\(range.title)"
        )
        button.toolTip = "搜索范围：\(range.title)"
        button.selectItem(withTitle: range.title)
        button.menu?.items.forEach { item in
            let itemRange = (item.representedObject as? HistoryRangePayload)?.range
            item.state = itemRange == range ? .on : .off
        }
    }

    func resignFocusIfNeeded(fallbackWindow: NSWindow?) {
        guard let searchField else { return }
        guard let window = searchField.window ?? fallbackWindow else { return }
        let firstResponder = window.firstResponder
        if firstResponder === searchField || firstResponder === searchField.currentEditor() {
            window.makeFirstResponder(nil)
        }
    }

    @objc
    private func handleSearchChange(_ sender: NSSearchField) {
        delegate?.toolbarSearchBridge(
            self,
            didChangeText: sender.stringValue,
            generation: sender.tag
        )
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        delegate?.toolbarSearchBridgeDidBeginEditing(self, generation: field.tag)
    }

    @objc
    private func handleHistorySearchRange(_ sender: NSPopUpButton) {
        guard
            let payload = sender.selectedItem?.representedObject as? HistoryRangePayload
        else { return }
        delegate?.toolbarSearchBridge(
            self,
            didSelectHistoryRange: payload.range,
            generation: payload.generation
        )
    }

    @objc
    private func handleHistorySearchRangeMenuItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? HistoryRangePayload else { return }
        delegate?.toolbarSearchBridge(
            self,
            didSelectHistoryRange: payload.range,
            generation: payload.generation
        )
    }

    private func makeHistorySearchRangeButton(generation: Int) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.controlSize = .small
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease.circle",
            accessibilityDescription: "搜索范围"
        )
        button.toolTip = "搜索范围"

        let menu = NSMenu(title: "搜索范围")
        for range in PlaybackHistorySearchRange.allCases {
            let item = NSMenuItem(
                title: range.title,
                action: #selector(handleHistorySearchRangeMenuItem(_:)),
                keyEquivalent: ""
            )
            item.representedObject = HistoryRangePayload(range: range, generation: generation)
            item.target = self
            menu.addItem(item)
        }
        button.menu = menu
        return button
    }

    private func configureHistoryRangeMenu(_ menu: NSMenu?, generation: Int) {
        menu?.items.forEach { item in
            let range: PlaybackHistorySearchRange?
            if let payload = item.representedObject as? HistoryRangePayload {
                range = payload.range
            } else if let rawValue = item.representedObject as? String {
                range = PlaybackHistorySearchRange(rawValue: rawValue)
            } else {
                range = PlaybackHistorySearchRange.allCases.first { $0.title == item.title }
            }
            guard let range else { return }
            item.representedObject = HistoryRangePayload(range: range, generation: generation)
            item.target = self
            item.action = #selector(handleHistorySearchRangeMenuItem(_:))
        }
    }

    private func firstSubview(
        in root: NSView,
        matching predicate: (NSView) -> Bool
    ) -> NSView? {
        if predicate(root) {
            return root
        }
        for subview in root.subviews {
            if let match = firstSubview(in: subview, matching: predicate) {
                return match
            }
        }
        return nil
    }
}
