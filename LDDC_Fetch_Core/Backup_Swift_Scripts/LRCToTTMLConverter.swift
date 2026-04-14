import Foundation

// MARK: - Models
struct LyricSegment {
    var time: Double
    var text: String
    var endTime: Double?
    var nextLineStart: Double?
}

struct LyricLine {
    var segments: [LyricSegment]
}

enum LyricType {
    case line
    case char
}

// MARK: - LRC to TTML Converter
class LRCToTTMLConverter {
    
    // MARK: - Metadata Patterns
    private let metadataPatterns: [String: String] = [
        "ti": "title",
        "ar": "artist",
        "al": "album",
        "by": "creator",
        "offset": "offset",
        "tool": "tool"
    ]
    
    // MARK: - Song Info Keywords
    private let songInfoKeywords: [String] = [
        "作词：", "作曲：", "编曲：", "制作：", "录音：", "混音：",
        "发行：", "出品：", "母带：", "监制：", "SP：", "OP：",
        "作词:", "作曲:", "编曲:", "制作:", "录音:", "混音:",
        "发行:", "出品:", "母带:", "监制:", "SP:", "OP:",
        "Lyrics:", "Music:", "Arrangement:", "Producer:",
        "Recording:", "Mixing:", "Mastering:", "作词", "作曲", "编曲", "制作", "录音", "混音", "发行", "出品", "母带", "监制", "SP", "OP",
        "Lyrics", "Music", "Arrangement", "Producer",
        "Recording", "Mixing", "Mastering", "和声", "编写", "%", "&", "/", "\\", "-"
    ]
    
    private let infoSymbols: [String] = ["@", "Studio", "Records", "Label", "Copyright", "©"]
    
    // MARK: - Public Methods
    
    /// Convert LRC file to TTML format
    func convert(lrcFilePath: String, outputFilePath: String? = nil, stripMetadata: Bool = true) throws -> String {
        // Read file with encoding fallback
        let lines = try readFileWithEncodingFallback(lrcFilePath)
        
        var metadata: [String: String] = [:]
        var lyricsData: [LyricLine] = []
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }
            
            // Parse metadata
            let lineMetadata = parseLRCMetadata(trimmedLine)
            metadata.merge(lineMetadata) { _, new in new }
            
            // Parse lyric lines (skip metadata-only lines)
            let isMetadataLine = metadataPatterns.keys.contains { tag in
                trimmedLine.contains("[\(tag):")
            }
            
            if !isMetadataLine {
                if let segments = parseLRCLineWithCharTiming(trimmedLine) {
                    lyricsData.append(LyricLine(segments: segments))
                }
            }
        }
        
        guard !lyricsData.isEmpty else {
            throw LRCConversionError.noValidLyricsData
        }
        
        // Filter song info lines if requested
        var processedLyricsData = lyricsData
        if stripMetadata {
            processedLyricsData = filterSongInfoLines(processedLyricsData)
        }
        
        guard !processedLyricsData.isEmpty else {
            throw LRCConversionError.noValidLyricsData
        }
        
        // Detect lyric type and calculate end times
        let lyricType = detectLyricType(processedLyricsData)
        
        if lyricType == .line {
            processedLyricsData = calculateLineEndTimes(processedLyricsData)
        } else {
            processedLyricsData = processedLyricsData.map { line in
                LyricLine(segments: calculateSegmentEndTimes(line.segments))
            }
        }
        
        // Create TTML structure
        let ttmlString = createTTMLStructure(metadata: metadata, lyricsData: processedLyricsData)
        
        // Determine output path
        let finalOutputPath: String
        if let outputFilePath = outputFilePath {
            finalOutputPath = outputFilePath
        } else {
            let inputURL = URL(fileURLWithPath: lrcFilePath)
            let defaultDir = inputURL.deletingLastPathComponent().appendingPathComponent("covered")
            
            try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
            
            let fileName = inputURL.deletingPathExtension().lastPathComponent + ".ttml"
            finalOutputPath = defaultDir.appendingPathComponent(fileName).path
        }
        
        // Write to file
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
        
        // Try GBK as last resort
        let cfEncoding = CFStringEncodings.GB_18030_2000
        let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding.rawValue))
        if let content = try? String(contentsOfFile: path, encoding: String.Encoding(rawValue: gbkEncoding)) {
            return content.components(separatedBy: .newlines)
        }
        
        throw LRCConversionError.fileReadFailed
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
        
        // Filter lines starting with *
        if trimmedText.hasPrefix("*") { return true }
        
        // Check keywords
        for keyword in songInfoKeywords {
            if trimmedText.contains(keyword) { return true }
        }
        
        // Check colon patterns
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
        
        // Check info symbols
        for symbol in infoSymbols {
            if trimmedText.contains(symbol) { return true }
        }
        
        // Check short ASCII with keywords
        if trimmedText.allSatisfy({ $0.isASCII }) && trimmedText.count < 15 {
            let lowercased = trimmedText.lowercased()
            if lowercased.contains("studio") || lowercased.contains("records") || 
               lowercased.contains("label") || lowercased.contains("copyright") {
                return true
            }
        }
        
        return false
    }
    
    private func filterSongInfoLines(_ lyricsData: [LyricLine]) -> [LyricLine] {
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
    
    private func parseLRCLineWithCharTiming(_ line: String) -> [LyricSegment]? {
        let pattern = "\\[(\\d+:\\d+\\.\\d+)\\]([^\\[]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        
        let matches = regex.matches(in: line, options: [], range: NSRange(line.startIndex..., in: line))
        if matches.isEmpty { return nil }
        
        var segments: [LyricSegment] = []
        let matchCount = matches.count
        
        for (i, match) in matches.enumerated() {
            let timeRange = Range(match.range(at: 1), in: line)!
            let textRange = Range(match.range(at: 2), in: line)!
            
            let timeStr = String(line[timeRange])
            let text = String(line[textRange])
            
            // Only filter pure whitespace, keep other characters including punctuation
            let trimmedText = text.trimmingCharacters(in: .whitespaces)
            if !trimmedText.isEmpty {
                var segment = LyricSegment(
                    time: parseTimeToSeconds(timeStr),
                    text: trimmedText,
                    endTime: nil,
                    nextLineStart: nil
                )
                
                // Check for line-level format (next timestamp has no text)
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
    
    private func detectLyricType(_ lyricsData: [LyricLine]) -> LyricType {
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
            
            // Use next_line_start if available
            if let nextLineStart = segment.nextLineStart {
                segment.endTime = nextLineStart
            } else if i + 1 < count && !lyricsData[i + 1].segments.isEmpty {
                // Use next line's start time
                segment.endTime = lyricsData[i + 1].segments[0].time
            } else {
                // Last line - estimate duration
                let textLen = segment.text.count
                let duration = max(2.0, Double(textLen) * 0.3)
                segment.endTime = segment.time + duration
            }
            
            result.append(LyricLine(segments: [segment]))
        }
        
        return result
    }
    
    private func calculateSegmentEndTimes(_ segments: [LyricSegment], defaultDuration: Double = 0.5) -> [LyricSegment] {
        var result: [LyricSegment] = []
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
    
    private func createTTMLStructure(metadata: [String: String], lyricsData: [LyricLine]) -> String {
        var xmlParts: [String] = []
        
        xmlParts.append("<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" xmlns:amll=\"http://www.example.com/ns/amll\" xmlns:itunes=\"http://music.apple.com/lyric-ttml-internal\">")
        
        xmlParts.append("<head>")
        xmlParts.append("<metadata>")
        xmlParts.append("<ttm:agent type=\"person\" xml:id=\"v1\" />")
        xmlParts.append("<ttm:agent type=\"other\" xml:id=\"v2\" />")
        xmlParts.append("</metadata>")
        xmlParts.append("</head>")
        
        // Body
        var bodyAttrs: [String] = []
        
        // Calculate duration
        let allSegments = lyricsData.flatMap { $0.segments }
        if let lastSegment = allSegments.last {
            let lastTime = lastSegment.endTime ?? lastSegment.time
            bodyAttrs.append("dur=\"" + formatTimeForTTML(lastTime) + "\"")
        }
        
        xmlParts.append("<body" + (bodyAttrs.isEmpty ? "" : " " + bodyAttrs.joined(separator: " ")) + ">")
        
        // Div
        var divAttrs: [String] = []
        if !allSegments.isEmpty {
            let firstTime = allSegments.map { $0.time }.filter { $0 > 0 }.min() ?? 0
            let lastTime = allSegments.compactMap { $0.endTime ?? $0.time }.max() ?? 0
            divAttrs.append("begin=\"" + formatTimeForTTML(firstTime) + "\"")
            divAttrs.append("end=\"" + formatTimeForTTML(lastTime) + "\"")
        }
        xmlParts.append("<div" + (divAttrs.isEmpty ? "" : " " + divAttrs.joined(separator: " ")) + ">")
        
        // Paragraphs
        for (i, lineData) in lyricsData.enumerated() {
            guard !lineData.segments.isEmpty else { continue }
            
            let lineStart = lineData.segments[0].time
            let lineEnd = lineData.segments.last?.endTime ?? lineData.segments.last!.time + 1.0
            
            xmlParts.append("<p ttm:agent=\"v1\" itunes:key=\"L\(i + 1)\" begin=\"" + formatTimeForTTML(lineStart) + "\" end=\"" + formatTimeForTTML(lineEnd) + "\">")
            
            // Add character-level span elements
            let segments = lineData.segments
            for (j, segment) in segments.enumerated() {
                let begin = formatTimeForTTML(segment.time)
                let end = formatTimeForTTML(segment.endTime ?? segment.time + 0.5)
                let text = escapeXML(segment.text)
                
                // Build span with tail space if needed
                var span = "<span begin=\"\(begin)\" end=\"\(end)\">\(text)</span>"
                
                // Add space between English words using tail attribute simulation
                if j < segments.count - 1 {
                    if isEnglishWord(segment.text) {
                        let nextSegment = segments[j + 1]
                        if isEnglishWord(nextSegment.text) {
                            span += " " // Append space after span
                        }
                    }
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

// MARK: - Errors
enum LRCConversionError: Error {
    case fileReadFailed
    case noValidLyricsData
    case invalidOutputPath
}

// MARK: - Command Line Interface
if CommandLine.arguments.count > 1 {
    let converter = LRCToTTMLConverter()
    
    // Parse arguments
    var inputFile: String?
    var outputFile: String?
    var stripMetadata = true
    
    let args = CommandLine.arguments
    for (i, arg) in args.enumerated() {
        if arg == "-i" || arg == "--input" {
            if i + 1 < args.count { inputFile = args[i + 1] }
        } else if arg == "-o" || arg == "--output" {
            if i + 1 < args.count { outputFile = args[i + 1] }
        } else if arg == "--no-strip-metadata" {
            stripMetadata = false
        }
    }
    
    if let inputFile = inputFile {
        do {
            let outputPath = try converter.convert(lrcFilePath: inputFile, outputFilePath: outputFile, stripMetadata: stripMetadata)
            print("✅ Conversion successful!")
            print("📁 Input: \(inputFile)")
            print("📁 Output: \(outputPath)")
            
            let inputSize = (try? FileManager.default.attributesOfItem(atPath: inputFile)[.size] as? Int) ?? 0
            let outputSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
            print("📊 File size: \(inputSize) bytes → \(outputSize) bytes")
        } catch {
            print("❌ Conversion failed: \(error)")
            exit(1)
        }
    } else {
        print("Usage: swift LRCToTTMLConverter.swift -i <input.lrc> [-o <output.ttml>] [--no-strip-metadata]")
        exit(1)
    }
}
