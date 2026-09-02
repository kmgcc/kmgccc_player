//
//  AppKitFullTextScrollView.swift
//  myPlayer2
//
//  A small AppKit bridge for long, read-only text that must remain fully
//  readable inside a fixed-height SwiftUI surface.
//

import AppKit
import SwiftUI

/// Keeps the full document in AppKit's text system instead of asking a
/// SwiftUI `Text` inside a `ScrollView` to negotiate its unbounded intrinsic
/// height on every parent layout pass.
///
/// SwiftUI remains the source of truth for the document and its style. The
/// wrapped `NSTextView` owns only the scrollable presentation and is updated
/// when the document or text style actually changes.
struct AppKitFullTextScrollView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor
    var lineSpacing: CGFloat = 0
    var showsVerticalScroller = false
    var onClick: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        let textView = NSTextView(frame: .zero)
        configure(scrollView: scrollView, textView: textView, coordinator: context.coordinator)
        context.coordinator.onClick = onClick
        applyTextIfNeeded(to: textView, coordinator: context.coordinator, resetScroll: false)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        scrollView.hasVerticalScroller = showsVerticalScroller
        context.coordinator.onClick = onClick

        let textChanged = context.coordinator.lastText != text
        let styleChanged = !sameFont(context.coordinator.lastFont, font)
            || !sameColor(context.coordinator.lastTextColor, textColor)
            || context.coordinator.lastLineSpacing != lineSpacing

        guard textChanged || styleChanged else { return }
        applyTextIfNeeded(to: textView, coordinator: context.coordinator, resetScroll: textChanged)
    }

    final class Coordinator: NSObject {
        var lastText: String?
        var lastFont: NSFont?
        var lastTextColor: NSColor?
        var lastLineSpacing: CGFloat?
        var onClick: (() -> Void)?

        @objc func handleTextClick(_ sender: NSClickGestureRecognizer) {
            guard sender.state == .ended else { return }
            onClick?()
        }
    }

    private func configure(scrollView: NSScrollView, textView: NSTextView, coordinator: Coordinator) {
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = showsVerticalScroller
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.textContainerInset = .zero
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        if let textContainer = textView.textContainer {
            textContainer.lineFragmentPadding = 0
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        let clickRecognizer = NSClickGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleTextClick(_:))
        )
        clickRecognizer.numberOfClicksRequired = 1
        textView.addGestureRecognizer(clickRecognizer)

        scrollView.documentView = textView
    }

    private func applyTextIfNeeded(
        to textView: NSTextView,
        coordinator: Coordinator,
        resetScroll: Bool
    ) {
        let previousOrigin = textView.enclosingScrollView?.contentView.bounds.origin
        let textChanged = coordinator.lastText != text
        let styleChanged = !sameFont(coordinator.lastFont, font)
            || !sameColor(coordinator.lastTextColor, textColor)
            || coordinator.lastLineSpacing != lineSpacing

        if textChanged || styleChanged {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing
            paragraphStyle.lineBreakMode = .byWordWrapping

            let attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraphStyle
                ]
            )
            textView.textStorage?.setAttributedString(attributedText)
        }

        coordinator.lastText = text
        coordinator.lastFont = font
        coordinator.lastTextColor = textColor
        coordinator.lastLineSpacing = lineSpacing

        if resetScroll {
            textView.scrollToBeginningOfDocument(nil)
        } else if let previousOrigin,
                  let scrollView = textView.enclosingScrollView {
            scrollView.contentView.scroll(to: previousOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func sameFont(_ lhs: NSFont?, _ rhs: NSFont) -> Bool {
        lhs?.isEqual(rhs) == true
    }

    private func sameColor(_ lhs: NSColor?, _ rhs: NSColor) -> Bool {
        lhs?.isEqual(rhs) == true
    }
}
