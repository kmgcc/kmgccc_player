import AppKit
import SwiftUI

/// A native suggestion field gives us an explicit selection callback, keeping
/// search drafts and highlighted completions out of persisted lyrics settings.
struct LyricsFontSearchField: NSViewRepresentable {
    @Binding var selection: String
    let families: [SystemFontFamily]
    let fontSize: CGFloat
    let textColor: Color

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: selection)
        field.placeholderString = String(localized: "搜索字体")
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.isAutomaticTextCompletionEnabled = true
        field.allowsWritingTools = false
        field.delegate = context.coordinator
        field.suggestionsDelegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: fontSize, weight: .medium)
        field.textColor = NSColor(textColor)
        field.isEnabled = context.environment.isEnabled
        context.coordinator.synchronizeSelection(in: field)
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.stopOutsideClickMonitoring()
        field.delegate = nil
        field.suggestionsDelegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, NSTextSuggestionsDelegate {
        typealias SuggestionItemType = SystemFontFamily

        var parent: LyricsFontSearchField
        private var committedFamily: String
        private var outsideClickMonitor: Any?

        init(parent: LyricsFontSearchField) {
            self.parent = parent
            committedFamily = parent.selection
        }

        func synchronizeSelection(in field: NSTextField) {
            guard committedFamily != parent.selection else { return }
            committedFamily = parent.selection
            replaceText(in: field, with: committedFamily)
        }

        func textField(_ textField: NSTextField, provideUpdatedSuggestions responseHandler: @escaping (ItemResponse) -> Void) {
            let matches = SystemFontFamilySearch.matches(
                in: parent.families,
                query: textField.stringValue,
                selectedFamily: parent.selection
            )
            let items = matches.map { family in
                // Every candidate uses the system UI font; no typeface previews.
                var item = Item(representedValue: family, title: family.displayName)
                if family.displayName != family.name {
                    item.secondaryTitle = family.name
                }
                return item
            }
            responseHandler(ItemResponse(items: items))
        }

        func textField(_ textField: NSTextField, textCompletionFor item: Item) -> String? {
            // An alias or fuzzy query need not prefix the family name. Keep
            // that query intact while browsing; didSelect applies the result.
            nil
        }

        func textField(_ textField: NSTextField, didSelect item: Item) {
            commit(item.representedValue.name, in: textField)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let field = control as? NSTextField, !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                replaceText(in: field, with: parent.selection)
                return true
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty,
               let family = SystemFontFamilySearch.matches(
                   in: parent.families,
                   query: query,
                   selectedFamily: parent.selection,
                   limit: 1
               ).first {
                commit(family.name, in: field)
            } else {
                replaceText(in: field, with: parent.selection)
            }
            return true
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            // Replace the saved family on the first keystroke rather than
            // appending to it; a second click still places the caret.
            guard let field = notification.object as? NSTextField else { return }
            field.currentEditor()?.selectAll(nil)
            startOutsideClickMonitoring(in: field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            stopOutsideClickMonitoring()
            guard let field = notification.object as? NSTextField else { return }
            replaceText(in: field, with: parent.selection)
        }

        /// Ends editing when the click lands on anything but the field. AppKit
        /// leaves the field editor as the window's first responder when the
        /// click target cannot take focus, so a blank area would otherwise
        /// keep the field focused. The click itself is never consumed.
        private func startOutsideClickMonitoring(in field: NSTextField) {
            guard outsideClickMonitor == nil else { return }
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak field] event in
                guard let field, let window = field.window, event.window === window else { return event }
                let point = field.convert(event.locationInWindow, from: nil)
                guard !field.bounds.contains(point) else { return event }
                window.makeFirstResponder(nil)
                return event
            }
        }

        func stopOutsideClickMonitoring() {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
            }
            outsideClickMonitor = nil
        }

        private func commit(_ family: String, in field: NSTextField) {
            committedFamily = family
            replaceText(in: field, with: family)
            if parent.selection != family {
                parent.selection = family
            }
        }

        private func replaceText(in field: NSTextField, with text: String) {
            field.stringValue = text
            if let editor = field.currentEditor() {
                editor.string = text
                editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
        }
    }
}
