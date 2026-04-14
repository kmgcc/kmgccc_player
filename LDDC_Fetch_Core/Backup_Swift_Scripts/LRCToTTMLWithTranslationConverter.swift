import Foundation

// MARK: - Models
struct TranslationLyricSegment {
    var time: Double
    var text: String
    var endTime: Double?
    var nextLineStart: Double?
}

struct TranslationLyricLine {
    var segments: [TranslationLyricSegment]
}

enum TranslationLyricType {
    case line
    case char
}

// MARK: - LRC to TTML With Translation Converter
class LRCToTTMLWithTranslationConverter {
    
    private let metadataPatterns: [String: String] = [
        "ti": "title",
        "ar": "artist",
        "al": "album",
        "by": "creator",
        "offset": "offset",
        "tool": "tool"
    ]
    
    private let songInfoKeywords: [String] = [
        "作词：", "作曲：", "编曲：", "制作：", "录音：", "混音：",
        "发行：", "出品：", "母带：", "监制：", "SP：", "OP：",
        "作词:", "作曲:", "编曲:", "制作:", "录音:", "混音:",
        "发行:", "出品:", "母带:", "监制:", "SP:", "OP:",
        "Lyrics:", "Music:", "Arrangement:", "Producer:",
        "Recording:", "Mixing:", "Mastering:", "作词", "作曲", "编曲", "制作", "录音", "混音", "发行", "出品", "母带", "监制", "SP", "OP",
        "Lyrics", "Music", "Arrangement", "Producer",
        "Recording", "Mixing", "Mastering", "和声", "编写", "%", "&", "/", "\\", "-",
        "TME享有本翻译作品的著作权"
    ]
    
    private let infoSymbols: [String] = ["@", "Studio", "Records", "Label", "Copyright", "©"]
    
    // MARK: - Public Methods
    
    func convertWithTranslation(
        origLRCPath: String,
        transLRCPath: String,
        outputFilePath: String? = nil,
        stripMetadata: Bool = true
    ) throws -> String {
        // Parse original LRC
        let origLines = try readFileWithEncodingFallback(origLRCPath)
        
        var metadata: [String: String] = [:]
        var lyricsData: [TranslationLyricLine] = []
        
        for line in origLines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }
            
            let lineMetadata = parseLRCMetadata(trimmedLine)
            metadata.merge(lineMetadata) { _, new in new }
            
            let isMetadataLine = metadataPatterns.keys.contains { tag in
                trimmedLine.contains("[\(tag):")
            }
            
            if !isMetadataLine {
                if let segments = parseLRCLineWithCharTiming(trimmedLine) {
                    lyricsData.append(TranslationLyricLine(segments: segments))
                }
            }
        }
        
        guard !lyricsData.isEmpty else {
            throw TranslationConversionError.noValidLyricsData
        }
        
        if stripMetadata {
            lyricsData = filterSongInfoLines(lyricsData)
        }
        
        guard !lyricsData.isEmpty else {
            throw TranslationConversionError.noValidLyricsData
        }
        
        // Parse translation LRC
        let translations = try parseTranslationLRC(transLRCPath, stripMetadata: stripMetadata)
        
        // Detect lyric type and calculate end times
        let lyricType = detectLyricType(lyricsData)
        
        if lyricType == .line {
            lyricsData = calculateLineEndTimes(lyricsData)
        } else {
            lyricsData = lyricsData.map { line in
                TranslationLyricLine(segments: calculateSegmentEndTimes(line.segments))
            }
        }
        
        // Create TTML with translation
        let ttmlString = createTTMLStructureWithTranslation(metadata: metadata, lyricsData: lyricsData, translations: translations)
        
        // Determine output path
        let finalOutputPath: String
        if let outputFilePath = outputFilePath {
            finalOutputPath = outputFilePath
        } else {
            let inputURL = URL(fileURLWithPath: origLRCPath)
            let defaultDir = inputURL.deletingLastPathComponent().appendingPathComponent("covered")
            
            try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
            
            // Remove [Original] suffix
            var stem = inputURL.deletingPathExtension().lastPathComponent
            if stem.hasSuffix(" [Original]") {
                stem = String(stem.dropLast(11))
            }
            
            finalOutputPath = defaultDir.appendingPathComponent("\(stem).ttml").path
        }
        
        try ttmlString.write(toFile: finalOutputPath, atomically: true, encoding: .utf8)
        
        return finalOutputPath
    }
    
    // MARK: - Private Methods
    
    private func readFileWithEncodingFallback(_ path: String) throws -> [String] {
        let encodings: [String.Encoding] = [.utf8, .shiftJIS, .isoLatin1]
        
        for encoding in encodings {
            if let content = try? String(contentsOfFile: path, encoding: encoding) {
                return content.components(separatedBy: .newlines)
            }
        }
        
        let cfEncoding = CFStringEncodings.GB_18030_2000
        let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding.rawValue))
        if let content = try? String(contentsOfFile: path, encoding: String.Encoding(rawValue: gbkEncoding)) {
            return content.components(separatedBy: .newlines)
        }
        
        throw TranslationConversionError.fileReadFailed
    }
    
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
    
    private func parseTimeToSeconds(_ timeStr: String) -> Double {
        let pattern = "^(\\d+):(\\d+)\\.(\\d+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: timeStr, options: [], range: NSRange(timeStr.startIndex..., in: timeStr)) else {
            return 0
        }
        
        let minutesRange = Range(match.range(at: 1), in: timeStr)!
        let secondsRange = Range(match.range(at: 2), in: timeStr)!
        let millisecondsRange = Range(match.range(at: 3), in: timeStr)!
        
        let minutes = Int(timeStr[minutesRange]) ?? 0
        let seconds = Int(timeStr[secondsRange]) ?? 0
        let milliseconds = Int(timeStr[millisecondsRange]) ?? 0
        
        return Double(minutes * 60 + seconds) + Double(milliseconds) / 1000.0
    }
    
    private func formatTimeForTTML(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds)
        let minutes = Int(safeSeconds / 60)
        let secs = safeSeconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%06.3f", minutes, secs)
    }
    
    private func isSongInfoLine(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty { return false }
        
        if trimmedText.hasPrefix("*") { return true }
        
        for keyword in songInfoKeywords {
            if trimmedText.contains(keyword) { return true }
        }
        
        let colonPatterns = [
            "^[^:：]*(?:作词|作曲|编曲|制作|录音|混音|发行|出品|母带|监制|SP|OP|词|曲|)[^:：]*[:：]",
            "^[^:：]*(?:Lyrics|Music|Arrangement|Producer|Recording|Mixing|Mastering)[^:：]*[:：]",
            "^[^:：]*(?:by|By|BY)[^:：]*[:：]",
            "^[^:：]*(?:Studio|Label|Records)[^:：]*[:：]"
        ]
        
        for pattern in colonPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: trimmedText, options: [], range: NSRange(trimmedText.startIndex..., in: trimmedText)) != nil {
                return true
            }
        }
        
        for symbol in infoSymbols {
            if trimmedText.contains(symbol) { return true }
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
    
    private func filterSongInfoLines(_ lyricsData: [TranslationLyricLine]) -> [TranslationLyricLine] {
        var lastInfoIndex = -1
        
        for (i, lineData) in lyricsData.enumerated() {
            for segment in lineData.segments {
                if isSongInfoLine(segment.text) {
                    lastInfoIndex = i
                    break
                }
            }
        }
        
        if lastInfoIndex >= 0 {
            return Array(lyricsData[(lastInfoIndex + 1)...])
        }
        
        return lyricsData
    }
    
    private func parseLRCLineWithCharTiming(_ line: String) -> [TranslationLyricSegment]? {
        let pattern = "\\[(\\d+:\\d+\\.\\d+)\\]([^\\[]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        
        let matches = regex.matches(in: line, options: [], range: NSRange(line.startIndex..., in: line))
        if matches.isEmpty { return nil }
        
        var segments: [TranslationLyricSegment] = []
        let matchCount = matches.count
        
        for (i, match) in matches.enumerated() {
            let timeRange = Range(match.range(at: 1), in: line)!
            let textRange = Range(match.range(at: 2), in: line)!
            
            let timeStr = String(line[timeRange])
            let text = String(line[textRange])
            
            let trimmedText = text.trimmingCharacters(in: .whitespaces)
            if !trimmedText.isEmpty {
                var segment = TranslationLyricSegment(
                    time: parseTimeToSeconds(timeStr),
                    text: trimmedText,
                    endTime: nil,
                    nextLineStart: nil
                )
                
                if i + 1 < matchCount {
                    let nextTextRange = Range(matches[i + 1].range(at: 2), in: line)!
                    let nextText = String(line[nextTextRange]).trimmingCharacters(in: .whitespaces)
                    if nextText.isEmpty {
                        let nextTimeRange = Range(matches[i + 1].range(at: 1), in: line)!
                        segment.nextLineStart = parseTimeToSeconds(String(line[nextTimeRange]))
                    }
                }
                
                segments.append(segment)
            }
        }
        
        return segments.isEmpty ? nil : segments
    }
    
    private func parseTranslationLRC(_ lrcFilePath: String, stripMetadata: Bool) throws -> [Double: String] {
        var translations: [Double: String] = [:]
        let lines = try readFileWithEncodingFallback(lrcFilePath)
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }
            
            // Skip metadata lines
            let isMetadataLine = metadataPatterns.keys.contains { tag in
                trimmedLine.contains("[\(tag):")
            }
            if isMetadataLine { continue }
            
            // Parse timestamp and text
            let pattern = "^\\[(\\d+:\\d+\\.\\d+)\\](.+)$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: trimmedLine, options: [], range: NSRange(trimmedLine.startIndex..., in: trimmedLine)) else {
                continue
            }
            
            let timeRange = Range(match.range(at: 1), in: trimmedLine)!
            let textRange = Range(match.range(at: 2), in: trimmedLine)!
            
            let timeStr = String(trimmedLine[timeRange])
            let text = String(trimmedLine[textRange]).trimmingCharacters(in: .whitespaces)
            
            // Filter song info lines if requested
            if stripMetadata && isSongInfoLine(text) {
                continue
            }
            
            let startTime = parseTimeToSeconds(timeStr)
            translations[startTime] = text
        }
        
        return translations
    }
    
    private func findTranslationForLine(_ lineStartTime: Double, _ translations: [Double: String], tolerance: Double = 0.5) -> String? {
        // Exact match
        if let translation = translations[lineStartTime] {
            return translation
        }
        
        // Tolerance match
        for (transTime, transText) in translations {
            if abs(transTime - lineStartTime) <= tolerance {
                return transText
            }
        }
        
        return nil
    }
    
    private func detectLyricType(_ lyricsData: [TranslationLyricLine]) -> TranslationLyricType {
        var charLevelIndicators = 0
        var lineLevelIndicators = 0
        
        for lineData in lyricsData {
            let segments = lineData.segments
            if segments.count > 3 {
                charLevelIndicators += 1
            } else if segments.count == 1 {
                lineLevelIndicators += 1
            }
        }
        
        return lineLevelIndicators > charLevelIndicators ? .line : .char
    }
    
    private func calculateLineEndTimes(_ lyricsData: [TranslationLyricLine]) -> [TranslationLyricLine] {
        var result: [TranslationLyricLine] = []
        let count = lyricsData.count
        
        for i in 0..<count {
            let lineData = lyricsData[i]
            guard !lineData.segments.isEmpty else {
                result.append(lineData)
                continue
            }
            
            var segment = lineData.segments[0]
            
            if let nextLineStart = segment.nextLineStart {
                segment.endTime = nextLineStart
            } else if i + 1 < count && !lyricsData[i + 1].segments.isEmpty {
                segment.endTime = lyricsData[i + 1].segments[0].time
            } else {
                let textLen = segment.text.count
                let duration = max(2.0, Double(textLen) * 0.3)
                segment.endTime = segment.time + duration
            }
            
            result.append(TranslationLyricLine(segments: [segment]))
        }
        
        return result
    }
    
    private func calculateSegmentEndTimes(_ segments: [TranslationLyricSegment], defaultDuration: Double = 0.5) -> [TranslationLyricSegment] {
        var result: [TranslationLyricSegment] = []
        let count = segments.count
        
        for i in 0..<count {
            var segment = segments[i]
            if i + 1 < count {
                segment.endTime = segments[i + 1].time
            } else {
                let textLen = segment.text.count
                let duration = max(defaultDuration, Double(textLen) * 0.2)
                segment.endTime = segment.time + duration
            }
            result.append(segment)
        }
        
        return result
    }
    
    private func createTTMLStructureWithTranslation(
        metadata: [String: String],
        lyricsData: [TranslationLyricLine],
        translations: [Double: String]
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
        
        for (i, lineData) in lyricsData.enumerated() {
            guard !lineData.segments.isEmpty else { continue }
            
            let lineStart = lineData.segments[0].time
            let lineEnd = lineData.segments.last?.endTime ?? lineData.segments.last!.time + 1.0
            
            xmlParts.append("<p begin=\"" + formatTimeForTTML(lineStart) + "\" end=\"" + formatTimeForTTML(lineEnd) + "\" ttm:agent=\"v1\" itunes:key=\"L\(i + 1)\">")
            
            // Add character-level span elements
            let segments = lineData.segments
            for (j, segment) in segments.enumerated() {
                let begin = formatTimeForTTML(segment.time)
                let end = formatTimeForTTML(segment.endTime ?? segment.time + 0.5)
                let text = escapeXML(segment.text)
                
                var span = "<span begin=\"\(begin)\" end=\"\(end)\">\(text)</span>"
                
                // Add space between English words
                if j < segments.count - 1 {
                    if isEnglishWord(segment.text) {
                        let nextSegment = segments[j + 1]
                        if isEnglishWord(nextSegment.text) {
                            span += " "
                        }
                    }
                }
                
                xmlParts.append(span)
            }
            
            // Find and add translation
            if let translation = findTranslationForLine(lineStart, translations) {
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
    
    private func isEnglishWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let hasAsciiLetter = trimmed.contains { $0.isASCII && $0.isLetter }
        return trimmed.allSatisfy { $0.isASCII } && hasAsciiLetter
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
}

enum TranslationConversionError: Error {
    case fileReadFailed
    case noValidLyricsData
    case invalidOutputPath
}

// MARK: - Command Line Interface
if CommandLine.arguments.count > 1 {
    let converter = LRCToTTMLWithTranslationConverter()
    
    var origFile: String?
    var transFile: String?
    var outputFile: String?
    var stripMetadata = true
    
    let args = CommandLine.arguments
    for (i, arg) in args.enumerated() {
        if arg == "-i" || arg == "--input" {
            if i + 1 < args.count { origFile = args[i + 1] }
        } else if arg == "-t" || arg == "--translation" {
            if i + 1 < args.count { transFile = args[i + 1] }
        } else if arg == "-o" || arg == "--output" {
            if i + 1 < args.count { outputFile = args[i + 1] }
        } else if arg == "--no-strip-metadata" {
            stripMetadata = false
        }
    }
    
    if let origFile = origFile, let transFile = transFile {
        do {
            let outputPath = try converter.convertWithTranslation(
                origLRCPath: origFile,
                transLRCPath: transFile,
                outputFilePath: outputFile,
                stripMetadata: stripMetadata
            )
            print("✅ Conversion successful!")
            print("📁 Original: \(origFile)")
            print("📁 Translation: \(transFile)")
            print("📁 Output: \(outputPath)")
            
            let outputSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
            print("📊 Output file size: \(outputSize) bytes")
        } catch {
            print("❌ Conversion failed: \(error)")
            exit(1)
        }
    } else {
        print("Usage: swift LRCToTTMLWithTranslationConverter.swift -i <orig.lrc> -t <trans.lrc> [-o <output.ttml>] [--no-strip-metadata]")
        exit(1)
    }
}
