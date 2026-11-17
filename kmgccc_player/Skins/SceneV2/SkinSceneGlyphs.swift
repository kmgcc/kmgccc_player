import AppKit
import CoreText
import SwiftUI

/// Resolves a scene text's `font` and `weight` to one Core Text font, shared by drawing and
/// measuring so a layout's measured widths match what is drawn.
///
/// `font` may be a PostScript name (`youyou-yisong`), a family name (`PingFang SC`) or empty for
/// the system font. A family takes the face nearest `weight`; a PostScript name is used as named.
nonisolated enum SkinFontResolver {
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSFont>()

    static func font(_ name: String, size: Double, weight: String) -> NSFont { lookup(name, size: size, weight: weight).font }

    /// `found` is false while the named font is not installed or registered (the system font stands in).
    static func lookup(_ name: String, size: Double, weight: String) -> (font: NSFont, found: Bool) {
        let key = "\(name)|\(weight)|\(size)" as NSString
        if let font = cache.object(forKey: key) { return (font, true) }
        let (resolved, found) = resolve(name, size: size, weight: weight)
        // A package font may not be registered yet; resolve it again next time.
        if found { cache.setObject(resolved, forKey: key) }
        return (resolved, found)
    }

    private static func resolve(_ name: String, size: Double, weight: String) -> (NSFont, Bool) {
        let system = NSFont.systemFont(ofSize: size, weight: nsWeight(weight))
        guard !name.isEmpty else { return (system, true) }
        let named = CTFontCreateWithName(name as CFString, size, nil)
        if CTFontCopyPostScriptName(named) as String == name { return (named as NSFont, true) }
        let attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: name,
                                           kCTFontTraitsAttribute: [kCTFontWeightTrait: nsWeight(weight).rawValue]]
        let family = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
        if CTFontCopyFamilyName(family) as String == name { return (family as NSFont, true) }
        // A full name such as "PingFang SC Semibold" falls back to Core Text's own matching.
        if (CTFontCopyFullName(named) as String).caseInsensitiveCompare(name) == .orderedSame { return (named as NSFont, true) }
        return (system, false)
    }

    static func nsWeight(_ name: String) -> NSFont.Weight {
        switch name {
        case "ultralight": .ultraLight
        case "thin": .thin
        case "light": .light
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: .regular
        }
    }
}

/// `subpixel` text: each glyph is filled as its outline instead of drawn from the text
/// rasteriser, which snaps glyphs to whole pixels and steps through sizes. Outlines move and
/// scale by fractions of a pixel, so slow drifts and camera zooms stay smooth.
struct SkinGlyphVector: Equatable, Sendable {
    /// The text's `font` and `weight`, resolved as `SkinFontResolver` does; missing characters
    /// fall back as Core Text does.
    var font: String
    var weight: String
    var size: Double
    var color: Color
    /// The characters drawn, one per glyph slice.
    var characters: [String]
}

nonisolated enum SkinGlyphOutlines {
    private nonisolated final class Box {
        let path: Path?
        init(_ path: Path?) { self.path = path }
    }
    nonisolated(unsafe) private static let paths = NSCache<NSString, Box>()

    /// The outline of `character` in the font, origin on the baseline, y down; nil when the
    /// character has no outline (emoji, a missing glyph) and must be drawn as text.
    static func path(_ character: String, font name: String, weight: String, size: Double) -> Path? {
        let key = "\(name)|\(weight)|\(size)|\(character)" as NSString
        if let box = paths.object(forKey: key) { return box.path }
        let base = SkinFontResolver.font(name, size: size, weight: weight) as CTFont
        let utf16 = Array(character.utf16)
        let font = CTFontCreateForString(base, character as CFString, CFRange(location: 0, length: utf16.count))
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        var outline: Path?
        if CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count), glyphs.count == 1 || glyphs.dropFirst().allSatisfy({ $0 == 0 }),
           glyphs[0] != 0, let cgPath = CTFontCreatePathForGlyph(font, glyphs[0], nil) {
            var flip = CGAffineTransform(scaleX: 1, y: -1)
            outline = cgPath.copy(using: &flip).map { Path($0) }
        }
        paths.setObject(Box(outline), forKey: key)
        return outline
    }
}
