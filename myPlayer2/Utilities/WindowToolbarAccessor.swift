//
//  WindowToolbarAccessor.swift
//  myPlayer2
//
//  TrueMusic - Window Toolbar Accessor
//  Allows small AppKit adjustments (e.g. removing default toolbar items).
//

import AppKit
import SwiftUI

/// A tiny NSViewRepresentable that exposes the hosting NSWindow for configuration.
struct WindowToolbarAccessor: NSViewRepresentable {

    let configure: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }

        // Avoid running repeatedly; SwiftUI updates frequently.
        if context.coordinator.lastConfiguredWindow !== window {
            context.coordinator.lastConfiguredWindow = window
            DispatchQueue.main.async {
                configure(window)
            }
        }
    }

    final class Coordinator {
        weak var lastConfiguredWindow: NSWindow?
    }
}
