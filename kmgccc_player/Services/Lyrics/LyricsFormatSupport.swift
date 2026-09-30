//
//  LyricsFormatSupport.swift
//  myPlayer2
//
//  Lightweight lyric format detection and TTML validation for app-side storage gates.
//

import Foundation

nonisolated enum LyricsFormatSupport {
    static func normalizedTTMLText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, validateTTML(trimmed).isValid else { return nil }
        return trimmed
    }

    static func validateManualTTML(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let result = validateTTML(trimmed)
        return result.isValid ? nil : result.message
    }

    static func validateTTML(_ text: String) -> TTMLValidationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid("歌词为空")
        }
        guard looksLikeTTML(trimmed) else {
            return .invalid("仅支持 TTML 歌词，请通过歌词搜索或自动导入流程转换 LRC/TXT。")
        }

        guard trimmed.range(of: #"<(?:\w+:)?tt(?:\s|>|/)"#, options: [.regularExpression, .caseInsensitive]) != nil,
              trimmed.range(of: #"</(?:\w+:)?tt\s*>"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return .invalid("未找到 TTML <tt> 根节点")
        }
        guard trimmed.range(of: #"<(?:\w+:)?body(?:\s|>|/)"#, options: [.regularExpression, .caseInsensitive]) != nil,
              trimmed.range(of: #"</(?:\w+:)?body\s*>"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return .invalid("TTML 缺少 <body> 节点")
        }
        return .valid
    }

    static func looksLikeTTML(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: #"<(?:\w+:)?tt(?:\s|>|/)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func looksLikeLRC(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        var timestampLineCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.range(of: #"\[(?:\d{1,3}):(?:[0-5]?\d)(?:[\.,]\d{1,3})?\]"#, options: .regularExpression) != nil {
                timestampLineCount += 1
                if timestampLineCount >= 1 { return true }
            }
        }
        return false
    }

    private static let pTagRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"<p\b[^>]*>(.*?)</p>"#,
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )
    private static let spanTagRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"<span\b([^>]*)>"#,
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )

    static func isWordSyncedTTML(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.localizedCaseInsensitiveContains("<span"),
              let pRegex = pTagRegex,
              let spanRegex = spanTagRegex else {
            return false
        }

        let nsString = trimmed as NSString
        let pMatches = pRegex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: nsString.length))

        for pMatch in pMatches {
            guard pMatch.numberOfRanges > 1 else { continue }
            let pRange = pMatch.range(at: 1)
            let pContent = nsString.substring(with: pRange)
            let pNSString = pContent as NSString
            let spanMatches = spanRegex.matches(in: pContent, options: [], range: NSRange(location: 0, length: pNSString.length))

            var timedWordSpans = 0
            for spanMatch in spanMatches {
                guard spanMatch.numberOfRanges > 1 else { continue }
                let attrRange = spanMatch.range(at: 1)
                let attrs = pNSString.substring(with: attrRange).lowercased()
                if attrs.contains("begin=") || attrs.contains("begin =") {
                    if !attrs.contains("x-translation") && !attrs.contains("x-roman") {
                        timedWordSpans += 1
                        if timedWordSpans > 1 {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    private static let creditKeywords: [String] = [
        "词", "作词", "填词", "曲", "作曲", "谱曲", "词曲", "编曲", "制作", "制作人", "音乐制作", "配唱制作", "配唱制作人",
        "人声", "主唱", "歌手", "原唱", "翻唱", "合唱", "和声", "合声", "和音", "吉他", "木吉他", "电吉他", "民谣吉他", "贝斯",
        "低音提琴", "鼓", "打击乐", "卡宏", "卡宏鼓", "键盘", "钢琴", "弦乐", "管乐", "管弦乐", "录音", "录音师", "录音棚", "录音室",
        "混音", "混音师", "混音室", "母带", "母带师", "企划", "监制", "出品", "出品人", "厂牌", "总监", "音乐总监", "统筹",
        "经纪", "经纪人", "设计", "封面设计", "插画", "宣传", "推广", "版权", "版权所有", "发行", "发行人", "发行公司", "唱片公司",
        "Lyricist", "Composer", "Arranger", "Producer", "Executive Producer", "Vocal", "Vocals", "Lead Vocal",
        "Guitar", "Bass", "Drum", "Drums", "Cajon", "Keyboard", "Piano", "Chorus", "Backing Vocal", "Recording",
        "Mixing", "Mastering", "Sound Engineer", "Artist", "Label", "OP", "SP"
    ]

    private static let creditColonRegex: NSRegularExpression? = {
        let pattern = #"(?:^|[\s\[\(\（\【])("# + creditKeywords.joined(separator: "|") + #")(?:\s*[\u4e00-\u9fa5a-zA-Z]{0,3})?\s*[:：]"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let soloSpeakerRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\s*[\u4e00-\u9fa5a-zA-Z0-9_/·&]{1,12}\s*[:：]\s*$"#
    )

    private static func isCreditOrNoiseLine(
        _ lineText: String,
        trackTitle: String?,
        artist: String?
    ) -> Bool {
        let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let ns = trimmed as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        if let regex = creditColonRegex, regex.firstMatch(in: trimmed, options: [], range: fullRange) != nil {
            return true
        }

        if let regex = soloSpeakerRegex, regex.firstMatch(in: trimmed, options: [], range: fullRange) != nil {
            return true
        }

        if trimmed.contains(" - ") {
            if let trackTitle, !trackTitle.isEmpty, trimmed.localizedCaseInsensitiveContains(trackTitle) {
                return true
            }
            if let artist, !artist.isEmpty, trimmed.localizedCaseInsensitiveContains(artist) {
                return true
            }
        }
        if trimmed.contains("（原唱") || trimmed.contains("(原唱") {
            return true
        }

        return false
    }

    /// Strips preamble and trailing metadata/credit lines from a TTML document,
    /// synchronizes the `<div begin="...">` attribute with the start of the first
    /// remaining line, and renumbers `itunes:key="L1"..."L<n>"`.
    /// Preserves all inner `<span begin="..." end="...">` word-level timing intact.
    static func sanitizeTTML(
        _ text: String,
        trackTitle: String? = nil,
        artist: String? = nil
    ) -> (sanitized: String, removedCount: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeTTML(trimmed), let pRegex = pTagRegex else {
            return (text, 0)
        }

        let fullRange = NSRange(location: 0, length: (trimmed as NSString).length)
        let matches = pRegex.matches(in: trimmed, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return (text, 0)
        }

        struct LineInfo {
            let fullTag: String
            let textContent: String
            let beginTime: String?
        }

        var lines: [LineInfo] = []
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let fullTag = (trimmed as NSString).substring(with: match.range(at: 0))
            let innerContent = (trimmed as NSString).substring(with: match.range(at: 1))
            let plainText = innerContent.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var beginTime: String?
            if let beginRange = fullTag.range(of: #"begin=\"([^\"]+)\""#, options: .regularExpression) {
                let sub = fullTag[beginRange]
                if let quote1 = sub.firstIndex(of: "\""),
                   let quote2 = sub.lastIndex(of: "\""),
                   quote1 < quote2 {
                    let inside = sub[sub.index(after: quote1)..<quote2]
                    beginTime = String(inside)
                }
            }
            lines.append(LineInfo(fullTag: fullTag, textContent: plainText, beginTime: beginTime))
        }

        // 1. Identify preamble lines (up to first 12 lines)
        var headRemove = 0
        for (idx, line) in lines.prefix(12).enumerated() {
            if isCreditOrNoiseLine(line.textContent, trackTitle: trackTitle, artist: artist) {
                headRemove = idx + 1
            } else {
                break
            }
        }

        // 2. Identify trailing credit lines (up to last 10 lines)
        var tailRemove = 0
        for idx in stride(from: lines.count - 1, through: max(0, lines.count - 10), by: -1) {
            let line = lines[idx]
            if isCreditOrNoiseLine(line.textContent, trackTitle: trackTitle, artist: artist) {
                tailRemove += 1
            } else {
                break
            }
        }

        let endIdx = lines.count - tailRemove
        guard headRemove < endIdx else {
            return (text, 0)
        }

        let removedCount = headRemove + tailRemove
        guard removedCount > 0 else {
            return (text, 0)
        }

        let keptLines = lines[headRemove..<endIdx]
        guard let firstKept = keptLines.first else {
            return (text, 0)
        }

        // Renumber itunes:key="L1"..."L<n>"
        var renumberedTags: [String] = []
        for (idx, line) in keptLines.enumerated() {
            var tag = line.fullTag
            tag = tag.replacingOccurrences(
                of: #"itunes:key=\"[^\"]+\""#,
                with: "itunes:key=\"L\(idx + 1)\"",
                options: .regularExpression
            )
            renumberedTags.append(tag)
        }

        guard let firstPMatch = matches.first,
              let lastPMatch = matches.last else {
            return (text, 0)
        }

        var prefix = (trimmed as NSString).substring(to: firstPMatch.range.location)
        let suffix = (trimmed as NSString).substring(from: lastPMatch.range.location + lastPMatch.range.length)

        if let firstBegin = firstKept.beginTime {
            prefix = prefix.replacingOccurrences(
                of: #"<div\s+begin=\"[^\"]+\""#,
                with: "<div begin=\"\(firstBegin)\"",
                options: .regularExpression
            )
        }

        let sanitized = prefix + renumberedTags.joined(separator: "\n") + suffix
        return (sanitized, removedCount)
    }
}

nonisolated enum TTMLValidationResult: Equatable {
    case valid
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var message: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}
