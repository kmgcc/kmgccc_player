//
//  ColorSystemDiagnostic.swift
//  myPlayer2
//
//  Debug helpers for tracing the OKLCH colour pipeline at runtime. Used by
//  `FullscreenPlayerView.applyFullscreenLyricsTheme` to dump the actual
//  colour set being pushed to the WebView so a "grey on screen" report can
//  be triaged as a Swift bug vs. a Web / CSS bug without rebuilding.
//

import AppKit
import Foundation

nonisolated enum ColorSystemDiagnostic {

    /// "#rrggbb (L=… C=… H=…)" so a single log line carries both the sRGB
    /// representation that DevTools would show and the OKLCH triple that the
    /// Tone Ladder works in.
    static func describe(_ color: NSColor) -> String {
        let hex = hexString(color)
        guard let lch = OKColor.nsColorToOKLCH(color) else {
            return "\(hex) (OKLCH=nil)"
        }
        return String(
            format: "%@ (L=%.3f C=%.3f H=%.3f)",
            hex,
            Double(lch.l),
            Double(lch.c),
            Double(lch.h)
        )
    }

    private static func hexString(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let r = clampByte(Int(round(rgb.redComponent * 255)))
        let g = clampByte(Int(round(rgb.greenComponent * 255)))
        let b = clampByte(Int(round(rgb.blueComponent * 255)))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func clampByte(_ v: Int) -> Int {
        Swift.max(0, Swift.min(255, v))
    }
}
