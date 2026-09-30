//
//  BundledFontRegistrar.swift
//  myPlayer2
//
//  Registers app-bundled fonts for the native SwiftUI/AppKit lyrics surface.
//

import CoreText
import Foundation

enum BundledFontRegistrar {
    static func register() {
        guard let url = Bundle.main.url(
            forResource: "Inter-VariableFont_opsz,wght",
            withExtension: "ttf",
            subdirectory: "AMLL/Fonts"
        ) else {
            return
        }

        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(
            url as CFURL,
            .process,
            &error
        )
    }
}
