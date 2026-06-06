//
//  LRCConverterService.swift
//  myPlayer2
//
//  Swift-native LRC to TTML conversion service
//  Replaces Python script functionality with native Swift implementation
//

import Foundation

private struct LyricSegment {
    var time: Double
    var text: String
    var leadingSpace: String = ""
    var trailingSpace: String = ""
    var endTime: Double?
    var nextLineStart: Double?
}

private struct LyricLine {
    var segments: [LyricSegment]
}

private struct TranslationLine {
    var time: Double
    var text: String
}

private enum LyricType {
    case line
    case char
}

private enum LRCConversionError: Error {
    case noValidLyricsData
    case fileReadFailed
    case invalidOutputPath
}

actor LRCConverterService {
    
    static let shared = LRCConverterService()
    
    private let metadataPatterns: [String: String] = [
        "ti": "title",
        "ar": "artist",
        "al": "album",
        "by": "creator",
        "offset": "offset",
        "tool": "tool"
    ]
    
    private let strictSongInfoKeywords: [String] = [
        "作词：", "作曲：", "编曲：", "制作：", "录音：", "混音：",
        "发行：", "出品：", "母带：", "监制：", "制作人：", "和声：",
        "统筹：", "企划：", "封面：", "SP：", "OP：",
        "作词:", "作曲:", "编曲:", "制作:", "录音:", "混音:",
        "发行:", "出品:", "母带:", "监制:", "制作人:", "和声:",
        "统筹:", "企划:", "封面:", "SP:", "OP:",
        "Lyrics:", "Music:", "Arrangement:", "Producer:",
        "Recording:", "Mixing:", "Mastering:",
        "版权", "未经许可", "不得翻唱", "不得使用",
        "TME", "QQ音乐", "网易云音乐", "酷狗", "酷我", "LDDC", "lddc", "tool:",
        "TME享有本翻译作品的著作权"
    ]

    private let conservativeSongInfoKeywords: [String] = [
        "版权", "未经许可", "不得翻唱", "不得使用",
        "TME", "QQ音乐", "网易云音乐", "酷狗", "酷我", "LDDC", "lddc", "tool:"
    ]

    private let bareConservativeInfoFields: Set<String> = [
        "Dario", "吉他", "出品", "制作", "发行", "OP", "SP", "词", "曲",
        "作词", "作曲", "编曲", "录音", "混音", "母带", "监制", "制作人",
        "和声", "统筹", "企划", "封面"
    ]

    private let infoFieldNames: [String] = [
        "Dario", "吉他", "出品", "制作", "发行", "OP", "SP", "词", "曲",
        "作词", "作曲", "编曲", "录音", "混音", "母带", "监制", "制作人",
        "和声", "统筹", "企划", "封面", "Lyrics", "Music", "Arrangement",
        "Producer", "Recording", "Mixing", "Mastering", "Studio", "Label", "Records"
    ]

    private let strictInfoSymbols: [String] = ["@", "Studio", "Records", "Label", "Copyright", "©"]
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Convert LRC content to TTML format
    func convertToTTML(lrcContent: String, stripMetadata: Bool = true) throws -> String {
        let lines = lrcContent.components(separatedBy: .newlines)
        
        var metadata: [String: String] = [:]
        var lyricsData: [LyricLine] = []
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }
            
            let lineMetadata = parseLRCMetadata(trimmedLine)
            metadata.merge(lineMetadata) { _, new in new }
            
            let isMetadataLine = metadataPatterns.keys.contains { tag in
                trimmedLine.contains("[\(tag):")
            }
            
            if !isMetadataLine {
                lyricsData.append(contentsOf: parseLRCLine(trimmedLine))
            }
        }
        
        guard !lyricsData.isEmpty else {
            throw LRCConversionError.noValidLyricsData
        }
        
        var processedLyricsData = lyricsData
        if stripMetadata {
            processedLyricsData = filterSongInfoLines(processedLyricsData)
        }
        
        guard !processedLyricsData.isEmpty else {
            throw LRCConversionError.noValidLyricsData
        }
        
        let lyricType = detectLyricType(processedLyricsData)
        
        switch lyricType {
        case .line:
            processedLyricsData = calculateLineEndTimes(processedLyricsData)
        case .char:
            processedLyricsData = processedLyricsData.enumerated().map { index, line in
                let nextLineStart = index + 1 < processedLyricsData.count
                    ? processedLyricsData[index + 1].segments.first?.time
                    : nil
                return LyricLine(segments: calculateSegmentEndTimes(line.segments, nextLineStart: nextLineStart))
            }
        }
        
        return createTTMLStructure(metadata: metadata, lyricsData: processedLyricsData)
    }
    
    /// Convert LRC content with translation to TTML format
    func convertToTTMLWithTranslation(
        origContent: String,
        transContent: String,
        stripMetadata: Bool = true
    ) throws -> String {
        // Parse original
        let origLines = origContent.components(separatedBy: .newlines)
        
        var metadata: [String: String] = [:]
        var lyricsData: [LyricLine] = []
        
        for line in origLines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }
            
            let lineMetadata = parseLRCMetadata(trimmedLine)
            metadata.merge(lineMetadata) { _, new in new }
            
            let isMetadataLine = metadataPatterns.keys.contains { tag in
                trimmedLine.contains("[\(tag):")
            }
            
            if !isMetadataLine {
                lyricsData.append(contentsOf: parseLRCLine(trimmedLine))
            }
        }
        
        guard !lyricsData.isEmpty else {
            throw LRCConversionError.noValidLyricsData
        }
        
        if stripMetadata {
            lyricsData = filterSongInfoLines(lyricsData)
        }
        
        guard !lyricsData.isEmpty else {
            throw LRCConversionError.noValidLyricsData
        }
        
        // Parse translation
        let translations = try parseTranslationLRC(transContent, stripMetadata: stripMetadata)
        
        // Calculate end times
        let lyricType = detectLyricType(lyricsData)
        
        switch lyricType {
        case .line:
            lyricsData = calculateLineEndTimes(lyricsData)
        case .char:
            lyricsData = lyricsData.enumerated().map { index, line in
                let nextLineStart = index + 1 < lyricsData.count
                    ? lyricsData[index + 1].segments.first?.time
                    : nil
                return LyricLine(segments: calculateSegmentEndTimes(line.segments, nextLineStart: nextLineStart))
            }
        }
        
        return createTTMLStructureWithTranslation(metadata: metadata, lyricsData: lyricsData, translations: translations)
    }
    
    // MARK: - Private Methods
    
    private func parseLRCMetadata(_ line: String) -> [String: String] {
        var metadata: [String: String] = [:]
        
        for (tag, key) in metadataPatterns {
            let pattern = "\\[\(tag):([^\\]]*)\\]"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) {
                let valueRange = Range(match.range(at: 1), in: line)!
                metadata[key] = String(line[valueRange]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        return metadata
    }
    
    private func parseTimeToSeconds(_ timeStr: String) -> Double? {
        let pattern = "^(\\d+):(\\d{1,2})(?:[\\.,](\\d{1,3}))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: timeStr, options: [], range: NSRange(timeStr.startIndex..., in: timeStr)) else {
            return nil
        }
        
        let minutesRange = Range(match.range(at: 1), in: timeStr)!
        let secondsRange = Range(match.range(at: 2), in: timeStr)!
        
        let minutes = Int(timeStr[minutesRange]) ?? 0
        let seconds = Int(timeStr[secondsRange]) ?? 0
        guard (0..<60).contains(seconds) else { return nil }

        let milliseconds: Int
        if match.range(at: 3).location != NSNotFound,
           let millisecondsRange = Range(match.range(at: 3), in: timeStr) {
            let raw = String(timeStr[millisecondsRange])
            let padded = raw.padding(toLength: 3, withPad: "0", startingAt: 0)
            milliseconds = Int(String(padded.prefix(3))) ?? 0
        } else {
            milliseconds = 0
        }
        
        return Double(minutes * 60 + seconds) + Double(milliseconds) / 1000.0
    }
    
    private func formatTimeForTTML(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds)
        let minutes = Int(safeSeconds / 60)
        let secs = safeSeconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%06.3f", minutes, secs)
    }
    
    private func isSongInfoLine(_ text: String, lineIndex: Int, allowShortSymbolOnly: Bool = true) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty { return false }

        if lineIndex < 10 {
            return isStrictSongInfoLine(trimmedText, allowShortSymbolOnly: allowShortSymbolOnly)
        }

        return isConservativeSongInfoLine(trimmedText)
    }

    private func isStrictSongInfoLine(_ trimmedText: String, allowShortSymbolOnly: Bool = true) -> Bool {
        if trimmedText.hasPrefix("*") { return true }
        if allowShortSymbolOnly && isShortSymbolOnlyLine(trimmedText) { return true }

        for keyword in strictSongInfoKeywords {
            if trimmedText.localizedCaseInsensitiveContains(keyword) { return true }
        }

        if matchesInfoFieldLine(trimmedText) { return true }

        for symbol in strictInfoSymbols {
            if trimmedText.localizedCaseInsensitiveContains(symbol) { return true }
        }

        if trimmedText.allSatisfy({ $0.isASCII }) && trimmedText.count < 15 {
            let lowercased = trimmedText.lowercased()
            if lowercased.contains("studio") || lowercased.contains("records") ||
               lowercased.contains("label") || lowercased.contains("copyright") {
                return true
            }
        }

        return false
    }

    private func isShortSymbolOnlyLine(_ trimmedText: String) -> Bool {
        guard trimmedText.count <= 8 else { return false }
        return trimmedText.allSatisfy { character in
            character.isWhitespace || character.isPunctuation || character.isSymbol
        }
    }

    private func isConservativeSongInfoLine(_ trimmedText: String) -> Bool {
        for keyword in conservativeSongInfoKeywords {
            if trimmedText.localizedCaseInsensitiveContains(keyword) { return true }
        }

        if bareConservativeInfoFields.contains(trimmedText) {
            return true
        }

        return matchesInfoFieldLine(trimmedText)
    }

    private func matchesInfoFieldLine(_ trimmedText: String) -> Bool {
        let escapedFields = infoFieldNames.map { NSRegularExpression.escapedPattern(for: $0) }
        let fieldAlternation = escapedFields.joined(separator: "|")
        let colonPatterns = [
            "^\\s*(?:\(fieldAlternation))\\s*[:：]",
            "^\\s*(?:\(fieldAlternation))\\s*[:：].*$"
        ]

        for pattern in colonPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: trimmedText, options: [], range: NSRange(trimmedText.startIndex..., in: trimmedText)) != nil {
                return true
            }
        }

        return false
    }
    
    private func filterSongInfoLines(_ lyricsData: [LyricLine]) -> [LyricLine] {
        lyricsData.enumerated().compactMap { index, lineData in
            let combinedText = lineData.segments.map(\.text).joined()
            if index < 10,
               isShortSymbolOnlyLine(combinedText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return nil
            }

            let hasSongInfo = lineData.segments.contains {
                isSongInfoLine($0.text, lineIndex: index, allowShortSymbolOnly: false)
            }
            return hasSongInfo ? nil : lineData
        }
    }
    
    private func parseLRCLine(_ line: String) -> [LyricLine] {
        let pattern = "\\[(\\d+:\\d{1,2}(?:[\\.,]\\d{1,3})?)\\]([^\\[]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        
        let matches = regex.matches(in: line, options: [], range: NSRange(line.startIndex..., in: line))
        if matches.isEmpty { return [] }

        let parsed = matches.compactMap { match -> (time: Double, rawText: String)? in
            guard let timeRange = Range(match.range(at: 1), in: line),
                  let textRange = Range(match.range(at: 2), in: line),
                  let time = parseTimeToSeconds(String(line[timeRange])) else {
                return nil
            }
            return (time, String(line[textRange]))
        }
        guard !parsed.isEmpty else { return [] }

        let nonEmptyTexts = parsed
            .map { $0.rawText.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parsed.count > 1,
           nonEmptyTexts.count == 1,
           parsed.last?.rawText.trimmingCharacters(in: .whitespaces).isEmpty == false {
            let text = parsed.last?.rawText.trimmingCharacters(in: .whitespaces) ?? ""
            return parsed.map { item in
                LyricLine(segments: [
                    LyricSegment(time: item.time, text: text)
                ])
            }
        }

        var segments: [LyricSegment] = []
        
        for (i, item) in parsed.enumerated() {
            let trimmedText = item.rawText.trimmingCharacters(in: .whitespaces)
            if !trimmedText.isEmpty {
                var segment = LyricSegment(
                    time: item.time,
                    text: trimmedText,
                    leadingSpace: leadingWhitespace(in: item.rawText),
                    trailingSpace: trailingWhitespace(in: item.rawText),
                    endTime: nil,
                    nextLineStart: nil
                )
                
                if i + 1 < parsed.count {
                    let nextText = parsed[i + 1].rawText.trimmingCharacters(in: .whitespaces)
                    if nextText.isEmpty {
                        segment.nextLineStart = parsed[i + 1].time
                    }
                }
                
                segments.append(segment)
            }
        }
        
        return segments.isEmpty ? [] : [LyricLine(segments: segments)]
    }
    
    private func parseTranslationLRC(_ content: String, stripMetadata: Bool) throws -> [TranslationLine] {
        var translations: [TranslationLine] = []
        let lines = content.components(separatedBy: .newlines)
        
        for (sourceLineIndex, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }
            
            let isMetadataLine = metadataPatterns.keys.contains { tag in
                trimmedLine.contains("[\(tag):")
            }
            if isMetadataLine { continue }
            
            let pattern = "^\\[(\\d+:\\d{1,2}(?:[\\.,]\\d{1,3})?)\\](.+)$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: trimmedLine, options: [], range: NSRange(trimmedLine.startIndex..., in: trimmedLine)) else {
                continue
            }
            
            let timeRange = Range(match.range(at: 1), in: trimmedLine)!
            let textRange = Range(match.range(at: 2), in: trimmedLine)!
            
            let timeStr = String(trimmedLine[timeRange])
            let text = String(trimmedLine[textRange]).trimmingCharacters(in: .whitespaces)

            if text.contains("//") {
                continue
            }
            
            if stripMetadata && isSongInfoLine(text, lineIndex: sourceLineIndex) {
                continue
            }
            
            guard let startTime = parseTimeToSeconds(timeStr) else { continue }
            translations.append(TranslationLine(time: startTime, text: text))
        }
        
        return translations
    }
    
    private func matchTranslationsToLines(
        lyricsData: [LyricLine],
        translations: [TranslationLine],
        earlyTolerance: Double = 0.8,
        fallbackTolerance: Double = 1.2
    ) -> [Int: String] {
        guard !lyricsData.isEmpty, !translations.isEmpty else { return [:] }

        var matches: [Int: (translation: TranslationLine, distance: Double)] = [:]

        for translation in translations {
            guard let targetIndex = translationTargetIndex(
                for: translation.time,
                lyricsData: lyricsData,
                earlyTolerance: earlyTolerance,
                fallbackTolerance: fallbackTolerance
            ), let lineStart = lyricsData[targetIndex].segments.first?.time else {
                continue
            }

            let distance = abs(translation.time - lineStart)
            if let existing = matches[targetIndex] {
                if distance < existing.distance {
                    matches[targetIndex] = (translation, distance)
                }
            } else {
                matches[targetIndex] = (translation, distance)
            }
        }

        return matches.mapValues { $0.translation.text }
    }

    private func translationTargetIndex(
        for translationTime: Double,
        lyricsData: [LyricLine],
        earlyTolerance: Double,
        fallbackTolerance: Double
    ) -> Int? {
        if let earlyStartMatch = lyricsData.indices
            .compactMap({ index -> (index: Int, lead: Double)? in
                guard let lineStart = lyricsData[index].segments.first?.time else { return nil }
                let lead = lineStart - translationTime
                guard lead > 0, lead <= earlyTolerance else { return nil }
                return (index, lead)
            })
            .min(by: { $0.lead < $1.lead }) {
            return earlyStartMatch.index
        }

        for index in lyricsData.indices {
            guard let lineStart = lyricsData[index].segments.first?.time else { continue }
            let nextLineStart = nextLineStart(after: index, in: lyricsData)
            if translationTime >= lineStart,
               nextLineStart.map({ translationTime < $0 }) ?? true {
                return index
            }
        }

        for index in lyricsData.indices {
            guard let lineStart = lyricsData[index].segments.first?.time else { continue }
            let nextLineStart = nextLineStart(after: index, in: lyricsData)
            if translationTime >= lineStart - earlyTolerance,
               nextLineStart.map({ translationTime < $0 }) ?? true {
                return index
            }
        }

        return lyricsData.indices
            .compactMap { index -> (index: Int, distance: Double)? in
                guard let lineStart = lyricsData[index].segments.first?.time else { return nil }
                return (index, abs(translationTime - lineStart))
            }
            .filter { $0.distance <= fallbackTolerance }
            .min { $0.distance < $1.distance }?
            .index
    }

    private func nextLineStart(after index: Int, in lyricsData: [LyricLine]) -> Double? {
        guard index + 1 < lyricsData.count else { return nil }
        return lyricsData[index + 1].segments.first?.time
    }
    
    private func detectLyricType(_ lyricsData: [LyricLine]) -> LyricType {
        var charLevelIndicators = 0
        var lineLevelIndicators = 0
        
        for lineData in lyricsData {
            let segments = lineData.segments
            if segments.count > 1 {
                charLevelIndicators += 1
            } else if segments.count == 1 {
                lineLevelIndicators += 1
            }
        }
        
        return lineLevelIndicators > charLevelIndicators ? .line : .char
    }
    
    private func calculateLineEndTimes(_ lyricsData: [LyricLine]) -> [LyricLine] {
        var result: [LyricLine] = []
        let count = lyricsData.count
        
        for i in 0..<count {
            let lineData = lyricsData[i]
            guard !lineData.segments.isEmpty else {
                result.append(lineData)
                continue
            }
            
            var segment = lineData.segments[0]
            
            if let explicitEnd = segment.nextLineStart {
                let clippedEnd: Double
                if i + 1 < count, !lyricsData[i + 1].segments.isEmpty {
                    let nextLineStart = lyricsData[i + 1].segments[0].time
                    clippedEnd = explicitEnd > nextLineStart ? nextLineStart : explicitEnd
                } else {
                    clippedEnd = explicitEnd
                }
                segment.endTime = max(segment.time, clippedEnd)
            } else if i + 1 < count && !lyricsData[i + 1].segments.isEmpty {
                segment.endTime = max(segment.time, lyricsData[i + 1].segments[0].time)
            } else {
                let textLen = segment.text.count
                let duration = max(2.0, Double(textLen) * 0.3)
                segment.endTime = segment.time + duration
            }
            
            result.append(LyricLine(segments: [segment]))
        }
        
        return result
    }
    
    private func calculateSegmentEndTimes(
        _ segments: [LyricSegment],
        nextLineStart: Double? = nil,
        defaultDuration: Double = 0.5
    ) -> [LyricSegment] {
        var result: [LyricSegment] = []
        let count = segments.count
        
        for i in 0..<count {
            var segment = segments[i]
            if i + 1 < count {
                segment.endTime = max(segment.time, segments[i + 1].time)
            } else if let explicitEnd = segment.nextLineStart {
                let clippedEnd = nextLineStart.map { explicitEnd > $0 ? $0 : explicitEnd } ?? explicitEnd
                segment.endTime = max(segment.time, clippedEnd)
            } else {
                let textLen = segment.text.count
                let duration = max(defaultDuration, Double(textLen) * 0.2)
                let inferredEnd = segment.time + duration
                if let nextLineStart, inferredEnd > nextLineStart {
                    segment.endTime = max(segment.time, nextLineStart)
                } else {
                    segment.endTime = inferredEnd
                }
            }
            result.append(segment)
        }
        
        return result
    }
    
    private func createTTMLStructure(metadata: [String: String], lyricsData: [LyricLine]) -> String {
        var xmlParts: [String] = []
        
        xmlParts.append("<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" xmlns:amll=\"http://www.example.com/ns/amll\" xmlns:itunes=\"http://music.apple.com/lyric-ttml-internal\">")
        
        xmlParts.append("<head>")
        xmlParts.append("<metadata>")
        xmlParts.append("<ttm:agent type=\"person\" xml:id=\"v1\" />")
        xmlParts.append("<ttm:agent type=\"other\" xml:id=\"v2\" />")
        xmlParts.append("</metadata>")
        xmlParts.append("</head>")
        
        var bodyAttrs: [String] = []
        let allSegments = lyricsData.flatMap { $0.segments }
        if let lastSegment = allSegments.last {
            let lastTime = lastSegment.endTime ?? lastSegment.time
            bodyAttrs.append("dur=\"" + formatTimeForTTML(lastTime) + "\"")
        }
        
        xmlParts.append("<body" + (bodyAttrs.isEmpty ? "" : " " + bodyAttrs.joined(separator: " ")) + ">")
        
        var divAttrs: [String] = []
        if !allSegments.isEmpty {
            let firstTime = allSegments.map { $0.time }.filter { $0 > 0 }.min() ?? 0
            let lastTime = allSegments.compactMap { $0.endTime ?? $0.time }.max() ?? 0
            divAttrs.append("begin=\"" + formatTimeForTTML(firstTime) + "\"")
            divAttrs.append("end=\"" + formatTimeForTTML(lastTime) + "\"")
        }
        xmlParts.append("<div" + (divAttrs.isEmpty ? "" : " " + divAttrs.joined(separator: " ")) + ">")
        
        for (i, lineData) in lyricsData.enumerated() {
            guard !lineData.segments.isEmpty else { continue }
            
            let lineStart = lineData.segments[0].time
            let lineEnd = lineData.segments.last?.endTime ?? lineData.segments.last!.time + 1.0
            
            xmlParts.append("<p ttm:agent=\"v1\" itunes:key=\"L\(i + 1)\" begin=\"" + formatTimeForTTML(lineStart) + "\" end=\"" + formatTimeForTTML(lineEnd) + "\">")
            
            let segments = lineData.segments
            for segment in segments {
                let begin = formatTimeForTTML(segment.time)
                let end = formatTimeForTTML(segment.endTime ?? segment.time + 0.5)
                let text = escapeXML(segment.text)
                
                var span = ""
                if !segment.leadingSpace.isEmpty {
                    span += escapeXML(segment.leadingSpace)
                }
                span += "<span begin=\"\(begin)\" end=\"\(end)\">\(text)</span>"
                if !segment.trailingSpace.isEmpty {
                    span += escapeXML(segment.trailingSpace)
                }
                
                xmlParts.append(span)
            }
            
            xmlParts.append("</p>")
        }
        
        xmlParts.append("</div>")
        xmlParts.append("</body>")
        xmlParts.append("</tt>")
        
        return xmlParts.joined()
    }
    
    private func createTTMLStructureWithTranslation(
        metadata: [String: String],
        lyricsData: [LyricLine],
        translations: [TranslationLine]
    ) -> String {
        var xmlParts: [String] = []
        
        xmlParts.append("<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" xmlns:amll=\"http://www.example.com/ns/amll\" xmlns:itunes=\"http://music.apple.com/lyric-ttml-internal\">")
        
        xmlParts.append("<head>")
        xmlParts.append("<metadata>")
        xmlParts.append("<ttm:agent type=\"person\" xml:id=\"v1\" />")
        xmlParts.append("</metadata>")
        xmlParts.append("</head>")
        
        var bodyAttrs: [String] = []
        let allSegments = lyricsData.flatMap { $0.segments }
        if let lastSegment = allSegments.last {
            let lastTime = lastSegment.endTime ?? lastSegment.time
            bodyAttrs.append("dur=\"" + formatTimeForTTML(lastTime) + "\"")
        }
        
        xmlParts.append("<body" + (bodyAttrs.isEmpty ? "" : " " + bodyAttrs.joined(separator: " ")) + ">")
        
        var divAttrs: [String] = []
        if !allSegments.isEmpty {
            let firstTime = allSegments.map { $0.time }.filter { $0 > 0 }.min() ?? 0
            let lastTime = allSegments.compactMap { $0.endTime ?? $0.time }.max() ?? 0
            divAttrs.append("begin=\"" + formatTimeForTTML(firstTime) + "\"")
            divAttrs.append("end=\"" + formatTimeForTTML(lastTime) + "\"")
        }
        xmlParts.append("<div" + (divAttrs.isEmpty ? "" : " " + divAttrs.joined(separator: " ")) + ">")

        let matchedTranslations = matchTranslationsToLines(lyricsData: lyricsData, translations: translations)
        
        for (i, lineData) in lyricsData.enumerated() {
            guard !lineData.segments.isEmpty else { continue }
            
            let lineStart = lineData.segments[0].time
            let lineEnd = lineData.segments.last?.endTime ?? lineData.segments.last!.time + 1.0
            
            xmlParts.append("<p begin=\"" + formatTimeForTTML(lineStart) + "\" end=\"" + formatTimeForTTML(lineEnd) + "\" ttm:agent=\"v1\" itunes:key=\"L\(i + 1)\">")
            
            let segments = lineData.segments
            for segment in segments {
                let begin = formatTimeForTTML(segment.time)
                let end = formatTimeForTTML(segment.endTime ?? segment.time + 0.5)
                let text = escapeXML(segment.text)
                
                var span = ""
                if !segment.leadingSpace.isEmpty {
                    span += escapeXML(segment.leadingSpace)
                }
                span += "<span begin=\"\(begin)\" end=\"\(end)\">\(text)</span>"
                if !segment.trailingSpace.isEmpty {
                    span += escapeXML(segment.trailingSpace)
                }
                
                xmlParts.append(span)
            }
            
            if let translation = matchedTranslations[i] {
                let transSpan = "<span ttm:role=\"x-translation\" xml:lang=\"zh-CN\">\(escapeXML(translation))</span>"
                xmlParts.append(transSpan)
            }
            
            xmlParts.append("</p>")
        }
        
        xmlParts.append("</div>")
        xmlParts.append("</body>")
        xmlParts.append("</tt>")
        
        return xmlParts.joined()
    }
    
    private func escapeXML(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        return result
    }

    private func leadingWhitespace(in text: String) -> String {
        let prefix = text.prefix { $0 == " " || $0 == "\t" }
        return prefix.isEmpty ? "" : " "
    }

    private func trailingWhitespace(in text: String) -> String {
        let suffix = text.reversed().prefix { $0 == " " || $0 == "\t" }
        return suffix.isEmpty ? "" : " "
    }
}
