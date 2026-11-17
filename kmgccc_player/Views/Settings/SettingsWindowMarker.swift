//
//  SettingsWindowMarker.swift
//  myPlayer2
//
//  kmgccc_player - Identifies the window that hosts the settings sheet.
//

import AppKit
import SwiftUI

/// Identifies the sheet that hosts settings so app-level keyboard handling can
/// leave playback and fullscreen shortcuts idle while settings is key.
@MainActor
enum SettingsWindowMarker {
    static let identifier = NSUserInterfaceItemIdentifier("kmgccc_player.settings")
}

struct SettingsWindowMarkerView: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView { MarkerView() }

    func updateNSView(_ nsView: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = SettingsWindowMarker.identifier
        }
    }
}
