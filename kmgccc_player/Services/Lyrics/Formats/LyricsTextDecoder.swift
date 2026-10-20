//
//  LyricsTextDecoder.swift
//  kmgccc_player
//
//  Decodes lyric file bytes. Lyric files are often written by Windows tools
//  in a legacy code page instead of UTF-8.
//

import Foundation

nonisolated enum LyricsTextDecoder {
    /// A byte order mark decides the encoding. Without one, UTF-8 is tried first, then
    /// GB18030 (Simplified Chinese), Big5 (Traditional Chinese) and Shift_JIS.
    /// Newlines are normalized to `\n`.
    static func decode(_ data: Data) -> String? {
        guard let text = decodedText(data) else { return nil }
        return text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func decodedText(_ data: Data) -> String? {
        for (mark, encoding) in byteOrderMarks where data.starts(with: mark) {
            return String(data: data.dropFirst(mark.count), encoding: encoding)
        }
        for encoding in encodingsWithoutByteOrderMark {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    private static let byteOrderMarks: [([UInt8], String.Encoding)] = [
        ([0xEF, 0xBB, 0xBF], .utf8),
        ([0xFF, 0xFE], .utf16LittleEndian),
        ([0xFE, 0xFF], .utf16BigEndian),
    ]

    private static let encodingsWithoutByteOrderMark: [String.Encoding] = [
        .utf8,
        encoding(.GB_18030_2000),
        encoding(.big5),
        .shiftJIS,
    ]

    private static func encoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}
