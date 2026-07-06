//
//  CornerAvoidanceInsetsReader.swift
//  myPlayer2
//
//  Uses safe-area insets for corner avoidance. Replace with NSView.LayoutRegion
//  when available in the project SDK.
//

import AppKit
import SwiftUI

final class CornerInsetsReaderView: NSView {
    var onInsetsChange: ((EdgeInsets) -> Void)?
    private var lastInsets: EdgeInsets = .init()

    override func layout() {
        super.layout()
        updateInsetsIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateInsetsIfNeeded()
    }

    private func updateInsetsIfNeeded() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let insets = currentCornerInsets()
        if !approximatelyEqualInsets(insets, lastInsets) {
            lastInsets = insets
            onInsetsChange?(insets)
        }
    }

    private func currentCornerInsets() -> EdgeInsets {
        let insets = safeAreaInsets
        return EdgeInsets(
            top: max(0, insets.top),
            leading: max(0, insets.left),
            bottom: max(0, insets.bottom),
            trailing: max(0, insets.right)
        )
    }

    private func approximatelyEqualInsets(_ lhs: EdgeInsets, _ rhs: EdgeInsets) -> Bool {
        let epsilon: CGFloat = 0.5
        return abs(lhs.top - rhs.top) < epsilon
            && abs(lhs.bottom - rhs.bottom) < epsilon
            && abs(lhs.leading - rhs.leading) < epsilon
            && abs(lhs.trailing - rhs.trailing) < epsilon
    }
}

struct CornerAvoidanceInsetsReader: NSViewRepresentable {
    @Binding var insets: EdgeInsets

    func makeNSView(context: Context) -> CornerInsetsReaderView {
        let view = CornerInsetsReaderView()
        view.onInsetsChange = { newInsets in
            insets = newInsets
        }
        return view
    }

    func updateNSView(_ nsView: CornerInsetsReaderView, context: Context) {
        nsView.onInsetsChange = { newInsets in
            insets = newInsets
        }
        nsView.needsLayout = true
    }
}

struct CornerAvoidingHorizontalPadding: ViewModifier {
    let extra: CGFloat
    @State private var insets: EdgeInsets = .init()

    func body(content: Content) -> some View {
        content
            .padding(.leading, insets.leading + extra)
            .padding(.trailing, insets.trailing + extra)
            .background(CornerAvoidanceInsetsReader(insets: $insets))
    }
}

extension View {
    func cornerAvoidingHorizontalPadding(_ extra: CGFloat) -> some View {
        modifier(CornerAvoidingHorizontalPadding(extra: extra))
    }
}
