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
        if Thread.isMainThread {
            configureIfNeeded(for: nsView, coordinator: context.coordinator)
        } else {
            DispatchQueue.main.async {
                configureIfNeeded(for: nsView, coordinator: context.coordinator)
            }
        }
    }

    private func configureIfNeeded(for nsView: NSView, coordinator: Coordinator) {
        guard let window = nsView.window else { return }

        // Only configure once per window instance to avoid repeated AppKit churn.
        let needsConfigure = coordinator.lastConfiguredWindow !== window

        guard needsConfigure else { return }
        coordinator.lastConfiguredWindow = window
        configure(window)
    }

    final class Coordinator {
        weak var lastConfiguredWindow: NSWindow?
    }
}
