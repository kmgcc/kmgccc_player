import AppKit
import CoreText
import NaturalLanguage

struct TextAtom {
    var word: LyricWord
    var chunk = 0
    var emphasis: EmphasisEnvelope?
    var characterOffset = 0
}

struct GlyphPlacement {
    var text: String
    var origin: CGPoint
    var width: Double
    var font: CTFont
    var characterIndex: Int?
}

struct WordPlacement {
    var atom: TextAtom
    var rect: CGRect
    var pieces: [GlyphPlacement]
    var width: Double
    var fontSize: Double
    var fadeHeight: Double
}

struct LineTextLayout {
    var words: [WordPlacement]
    var sublines: [GlyphPlacement]
    var height: Double
    var width: Double
    var fontSize: Double
    var isDynamic: Bool
}

struct GroupTextLayout {
    var main: LineTextLayout
    var background: LineTextLayout?
    var padding: Double
    var gap: Double
    var width: Double
    var collapsedHeight: Double { main.height + padding*2 }
    var expandedHeight: Double { collapsedHeight + (background.map { $0.height+gap } ?? 0) }
}

final class TextLayoutEngine {
    private(set) var layoutCount = 0
    func group(_ group: PreparedGroup, width: Double, config: LyricsConfiguration, dynamic: Bool, hasDuet: Bool) -> GroupTextLayout {
        layoutCount += 1
        let size = max(10,config.fontSize)
        let pad = width <= 500 ? 20.0 : size
        let inner = max(20,width-pad*2)
        let content = max(10,hasDuet ? inner*0.85-size*0.2 : inner-size*0.4)
        return GroupTextLayout(main:line(group.main,width:content,config:config,dynamic:dynamic,fontSize:size),
                               background:group.background.map { line($0,width:content,config:config,dynamic:dynamic,fontSize:max(10,size*0.7)) },
                               padding:size*0.4,gap:size*0.3,width:width)
    }

    /// Resolve one concrete face for the script represented by `text`.
    /// CoreText will fall back between families when a single font is used for
    /// a mixed lyric, but that also makes the CJK weight silently inherit the
    /// Latin face.  Selecting the family per script keeps the two fullscreen
    /// typography controls independent.
    private func font(_ config: LyricsConfiguration, size: Double, text: String? = nil) -> CTFont {
        let familyName: String = {
            guard let text, isCJK(text),
                  let cjk = config.fontNameCJK?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cjk.isEmpty else { return config.fontName }
            return cjk
        }()
        let base = NSFont(name: familyName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .semibold)
        let cssWeight = max(100, min(900, config.fontWeight * 500 + 400))

        // NSFontDescriptor's numeric weight trait is only a hint for many
        // families (Helvetica Neue and PingFang silently resolve every value
        // to the regular face).  Resolve a concrete family member instead so
        // the light/dark independent lyric weight settings actually reach the
        // glyph bitmap cache.
        if let family = base.familyName,
           let members = NSFontManager.shared.availableMembers(ofFontFamily: family) {
            struct Member {
                let name: String
                let label: String
                let weight: Double
            }
            let parsed: [Member] = members.compactMap { row in
                guard let name = row.first as? String, !name.isEmpty else { return nil }
                let label = row.count > 1 ? String(describing: row[1]) : name
                // availableMembers uses AppKit's 1...11 weight scale in the
                // third column.  Keep a finite fallback for unusual fonts.
                let weight = row.count > 2 ? ((row[2] as? NSNumber)?.doubleValue ?? 5) : 5
                return Member(name: name, label: label, weight: weight)
            }
            let italic = base.fontDescriptor.symbolicTraits.contains(.italic)
            let candidates = parsed.filter { member in
                let lower = member.label.lowercased()
                return lower.contains("italic") == italic
            }
            let pool = candidates.isEmpty ? parsed : candidates
            let tokens: [String]
            switch cssWeight {
            case ...150: tokens = ["ultralight", "ultra light", "extralight"]
            case ...250: tokens = ["thin"]
            case ...350: tokens = ["light"]
            case ...450: tokens = ["regular", "normal", "book"]
            case ...550: tokens = ["medium"]
            case ...650: tokens = ["semibold", "demibold", "demi", "medium"]
            case ...750: tokens = ["bold"]
            case ...850: tokens = ["heavy"]
            default: tokens = ["black"]
            }
            // AppKit's member labels are not consistent across families. In
            // particular, Inter exposes `ExtraBold`/`Black` while PingFang
            // exposes only `Semibold`; asking for an exact token therefore
            // made the 900 setting resolve to an arbitrary middle face. The
            // extrema are intentional: choose the lightest/thickest available
            // member, then use semantic labels for the middle CSS weights.
            let selected: Member?
            if cssWeight <= 150 {
                selected = pool.min { $0.weight < $1.weight }
            } else if cssWeight >= 850 {
                selected = pool.max { $0.weight < $1.weight }
            } else {
                selected = tokens.lazy.compactMap { token in
                    pool.first { $0.label.lowercased().contains(token) }
                }.first ?? pool.min {
                    abs($0.weight - appKitWeight(for: cssWeight))
                        < abs($1.weight - appKitWeight(for: cssWeight))
                }
            }
            if let selected,
               let resolved = NSFont(name: selected.name, size: size) {
                return resolved as CTFont
            }
        }

        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: config.fontWeight]
        ])
        return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
    }
    static func shape(_ text: String, font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):true]))
    }
    static func width(_ text: String, font: CTFont) -> Double { CTLineGetTypographicBounds(shape(text,font:font),nil,nil,nil) }

    /// Split a string into contiguous Latin/CJK runs.  A run keeps its own
    /// resolved face, so a mixed line never gets shaped entirely by whichever
    /// family CoreText happens to choose first.
    private func fontRuns(_ text: String, config: LyricsConfiguration, size: Double) -> [(text: String, font: CTFont)] {
        guard !text.isEmpty else { return [] }
        var result: [(text: String, font: CTFont)] = []
        var current = ""
        var currentIsCJK: Bool?
        for character in text {
            let value = String(character)
            let isCharacterCJK = isCJK(value)
            if let currentIsCJK, currentIsCJK != isCharacterCJK, !current.isEmpty {
                result.append((current, font(config, size: size, text: current)))
                current = ""
            }
            currentIsCJK = isCharacterCJK
            current.append(character)
        }
        if !current.isEmpty {
            result.append((current, font(config, size: size, text: current)))
        }
        return result
    }

    private func measuredWidth(_ text: String, config: LyricsConfiguration, size: Double) -> Double {
        fontRuns(text, config: config, size: size)
            .reduce(0) { $0 + Self.width($1.text, font: $1.font) }
    }

    private func select(_ layers: [LyricTextLayer], language: String) -> LyricTextLayer? {
        layers.first { $0.language == language } ?? layers.first { !language.isEmpty && $0.language.hasPrefix(language.split(separator:"-").first.map(String.init) ?? language) } ?? layers.first
    }

    private func line(_ original: LyricLine, width: Double, config: LyricsConfiguration, dynamic: Bool, fontSize: Double) -> LineTextLayout {
        var line = original
        let product = config.profile == .currentPlayer && config.surface != .coreReference
        var subConfig = config
        subConfig.fontName = config.translationFontName
        subConfig.fontNameCJK = config.translationFontName
        subConfig.fontWeight = config.translationFontWeight
        let subSize = max(6,config.translationFontSize ?? (product ? config.fontSize*0.75 : fontSize*0.5))
        let roman = config.showRomanization ? select(line.romanizations,language:config.romanizationLanguage) : nil
        if let roman, !roman.words.isEmpty {
            var cursor = 0
            for i in line.words.indices {
                let main = line.words[i].range
                var best: (index:Int,score:Double)?
                for j in cursor..<roman.words.count {
                    let sub = roman.words[j].range
                    if abs(main.start-sub.start)<=0.002 { best = (j,1); break }
                    let intersection = max(0,min(main.end,sub.end)-max(main.start,sub.start))
                    let score = intersection/max(0.001,max(main.end,sub.end)-min(main.start,sub.start))
                    if score >= 0.1 && score > (best?.score ?? 0) { best = (j,score) }
                    if sub.start >= main.end { break }
                }
                if let best { line.words[i].romanization = roman.words[best.index].text; cursor = best.index+1 }
            }
        }
        if !config.showRuby { for i in line.words.indices { line.words[i].ruby = [] } }
        var atoms = makeAtoms(line,profile:config.profile,dynamic:dynamic)
        for i in atoms.indices where atoms[i].word.obscene && config.obscenity != .disabled {
            let chars = Array(atoms[i].word.text)
            atoms[i].word.text = chars.enumerated().map { index,ch in
                if ch.isWhitespace || (config.obscenity == .partial && (index == 0 || index == chars.count-1)) { return String(ch) }
                return config.maskCharacter
            }.joined()
        }
        let hasRuby = atoms.contains { !$0.word.ruby.isEmpty }
        let hasRoman = config.showRomanization && atoms.contains { !$0.word.romanization.isEmpty }
        var words: [WordPlacement] = []
        let rowHeight = fontSize*(product ? 1.42 : 1.2) + (hasRuby ? fontSize*0.5 : 0) + (hasRoman ? fontSize*0.5 : 0)
        var atomWidths = atoms.map { atom -> Double in
            let base = measuredWidth(atom.word.text, config: config, size: fontSize)
            let ruby = measuredWidth(atom.word.ruby.map(\.text).joined(), config: config, size: max(10, fontSize*0.5))
            let roman = measuredWidth(atom.word.romanization, config: config, size: max(10, fontSize*0.5)) + (hasRoman ? fontSize*0.15 : 0)
            return max(base,ruby,roman)
        }
        // Preserve AMLL wrapper boundaries, with a safe fallback for a single overlong word.
        var chunks: [[Int]] = []
        for i in atoms.indices {
            if let last = chunks.last, atoms[last[0]].chunk == atoms[i].chunk { chunks[chunks.count-1].append(i) }
            else { chunks.append([i]) }
        }
        let widths = chunks.map { $0.reduce(0) { $0+atomWidths[$1] } }
        let texts = chunks.map { $0.map { atoms[$0].word.text }.joined() }
        let breaks = balancedBreaks(widths:widths,texts:texts,width:width)
        var rows: [[Int]] = [[]]
        for i in chunks.indices {
            if breaks.contains(i) && !rows[rows.count-1].isEmpty { rows.append([]) }
            rows[rows.count-1].append(contentsOf:chunks[i])
        }
        var y = 0.0
        for row in rows {
            let rowWidth = row.reduce(0) { $0+atomWidths[$1] }
            var x = line.isDuet ? max(0,width-rowWidth) : 0
            for i in row {
                let atom = atoms[i]
                if atom.word.text == "\n" { y += rowHeight; x = 0; continue }
                let w = atomWidths[i]
                // CTTypesetter is the native escape hatch for a pathological unbreakable token.
                let text = atom.word.text.trimmingCharacters(in:.whitespacesAndNewlines)
                if text.isEmpty { x += w; continue }
                let baseRuns = fontRuns(text, config: config, size: fontSize)
                let baseWidth = baseRuns.reduce(0) { $0 + Self.width($1.text, font: $1.font) }
                let baseX = max(0,(w-baseWidth)/2)
                let mainY = hasRuby ? fontSize*0.5 : 0
                var pieces: [GlyphPlacement] = []
                if atom.emphasis != nil && config.emphasis {
                    var cx = baseX
                    for (j,ch) in text.enumerated() {
                        let value = String(ch)
                        let charFont = font(config, size: fontSize, text: value)
                        let cw = Self.width(value, font: charFont)
                        pieces.append(.init(text:value,origin:CGPoint(x:cx,y:mainY),width:cw,font:charFont,characterIndex:atom.characterOffset+j)); cx += cw
                    }
                } else {
                    var cx = baseX
                    for run in baseRuns {
                        let runWidth = Self.width(run.text, font: run.font)
                        pieces.append(.init(text:run.text,origin:CGPoint(x:cx,y:mainY),width:runWidth,font:run.font))
                        cx += runWidth
                    }
                }
                if hasRuby {
                    let text = atom.word.ruby.map(\.text).joined()
                    let rubyRuns = fontRuns(text, config: config, size: max(10, fontSize*0.5))
                    let rw = rubyRuns.reduce(0) { $0 + Self.width($1.text, font: $1.font) }
                    if !text.isEmpty {
                        var rx = (w-rw)/2
                        for run in rubyRuns {
                            let runWidth = Self.width(run.text, font: run.font)
                            pieces.append(.init(text:run.text,origin:CGPoint(x:rx,y:0),width:runWidth,font:run.font))
                            rx += runWidth
                        }
                    }
                }
                if hasRoman, !atom.word.romanization.isEmpty {
                    let text = atom.word.romanization
                    let romanRuns = fontRuns(text, config: config, size: max(10, fontSize*0.5))
                    let rw = romanRuns.reduce(0) { $0 + Self.width($1.text, font: $1.font) }
                    var rx = (w-rw)/2
                    for run in romanRuns {
                        let runWidth = Self.width(run.text, font: run.font)
                        pieces.append(.init(text:run.text,origin:CGPoint(x:rx,y:mainY+fontSize*1.2),width:runWidth,font:run.font))
                        rx += runWidth
                    }
                }
                if w > width {
                    // Keep glyph identity/time; split at grapheme boundaries without dropping content.
                    var cx = 0.0, cy = 0.0
                    pieces = []
                    for (j,ch) in text.enumerated() {
                        let value = String(ch)
                        let charFont = font(config, size: fontSize, text: value)
                        let cw = Self.width(value, font: charFont)
                        if cx+cw>width && cx>0 { cx = 0; cy += rowHeight }
                        pieces.append(.init(text:value,origin:CGPoint(x:cx,y:cy+mainY),width:cw,font:charFont,characterIndex:atom.emphasis == nil ? nil : atom.characterOffset+j)); cx += cw
                    }
                    words.append(.init(atom:atom,rect:CGRect(x:x,y:y,width:width,height:rowHeight+cy),pieces:pieces,width:baseWidth,fontSize:fontSize,fadeHeight:rowHeight))
                    y += cy
                    atomWidths[i] = width
                } else {
                    words.append(.init(atom:atom,rect:CGRect(x:x,y:y,width:w,height:rowHeight),pieces:pieces,width:w,fontSize:fontSize,fadeHeight:rowHeight))
                }
                x += min(w,width)
            }
            y += rowHeight
        }
        // The core's -1em margin cancels most of the product's 1.05em bottom padding.
        y += original.isBackground ? fontSize*0.4 : (product ? fontSize*0.05 : 0)
        var sublines: [GlyphPlacement] = []
        func append(_ text: String) {
            guard !text.isEmpty else { return }
            let string = NSMutableAttributedString()
            for run in fontRuns(text, config: subConfig, size: subSize) {
                string.append(NSAttributedString(string: run.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): run.font]))
            }
            let typesetter = CTTypesetterCreateWithAttributedString(string)
            var offset = 0
            while offset<string.length {
                let count = max(1,CTTypesetterSuggestLineBreak(typesetter,offset,width))
                let s = (text as NSString).substring(with:NSRange(location:offset,length:min(count,string.length-offset)))
                let runs = fontRuns(s, config: subConfig, size: subSize)
                let lineWidth = runs.reduce(0) { $0 + Self.width($1.text, font: $1.font) }
                var x = line.isDuet ? max(0,width-lineWidth) : 0
                for run in runs {
                    let runWidth = Self.width(run.text, font: run.font)
                    sublines.append(.init(text:run.text,origin:CGPoint(x:x,y:y),width:runWidth,font:run.font))
                    x += runWidth
                }
                offset += count; y += subSize*(product ? 1.42 : 1.5)
            }
        }
        if config.showTranslation { append(select(line.translations,language:config.translationLanguage)?.text ?? "") }
        if let roman, roman.words.isEmpty { append(roman.text) }
        return LineTextLayout(words:words,sublines:sublines,height:max(fontSize*1.2,y),width:width,fontSize:fontSize,isDynamic:dynamic)
    }
}

private func appKitWeight(for cssWeight: Double) -> Double {
    switch cssWeight {
    case ...150: return 2
    case ...350: return 3
    case ...450: return 5
    case ...650: return 6
    case ...750: return 9
    default: return 11
    }
}

private func isCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
}

func makeAtoms(_ line: LyricLine, profile: LyricsProfile, dynamic: Bool) -> [TextAtom] {
    var atoms: [TextAtom] = [], chunk = 0, mergingLatin = false
    // The fall starts when the last authored word highlight has finished, not
    // when a paragraph's container range happens to end.  Imported TTML can
    // have either range slightly ahead of the words, so prefer the actual
    // word clock and only fall back to the line range for wordless/legacy
    // lines.  Every emphasis chunk in the line still receives this one shared
    // boundary.
    let emphasisLineEnd = line.words.map { $0.range.end }.max() ?? line.range.end
    for word in line.words {
        if !dynamic {
            let tokenizer = NLTokenizer(unit:.word); tokenizer.string = word.text
            // Include spaces/punctuation as independent nodes, matching the balancing policy.
            var cursor = word.text.startIndex
            tokenizer.enumerateTokens(in:word.text.startIndex..<word.text.endIndex) { range,_ in
                if range.lowerBound>cursor {
                    var w = word; w.text = String(word.text[cursor..<range.lowerBound]); w.id += "-\(atoms.count)"; atoms.append(.init(word:w,chunk:chunk)); chunk += 1
                }
                var w = word; w.text = String(word.text[range]); w.id += "-\(atoms.count)"; atoms.append(.init(word:w,chunk:chunk)); chunk += 1; cursor = range.upperBound; return true
            }
            if cursor<word.text.endIndex { var w = word; w.text = String(word.text[cursor...]); w.id += "-\(atoms.count)"; atoms.append(.init(word:w,chunk:chunk)); chunk += 1 }
            continue
        }
        if !word.ruby.isEmpty { atoms.append(.init(word:word,chunk:chunk)); chunk += 1; mergingLatin = false; continue }
        var parts: [String] = []
        var pending = "", previousSpace: Bool?
        for ch in word.text {
            let space = ch.isWhitespace
            if let prev = previousSpace, prev != space { parts.append(pending); pending = "" }
            pending.append(ch); previousSpace = space
        }
        if !pending.isEmpty { parts.append(pending) }
        let total = max(1,word.text.filter { !$0.isWhitespace }.utf16.count)
        var offset = 0
        for part in parts {
            let space = part.allSatisfy(\.isWhitespace)
            let split = isCJK(part) && word.romanization.isEmpty ? part.map(String.init) : [part]
            for text in split {
                let count = space ? 0 : text.utf16.count
                var w = word; w.text = text; w.id += "-\(atoms.count)"
                w.range = LyricRange(word.range.start+word.range.duration*Double(offset)/Double(total),word.range.start+word.range.duration*Double(offset+count)/Double(total))
                let latin = !space && !isCJK(text)
                if !latin || !mergingLatin { chunk += 1 }
                atoms.append(.init(word:w,chunk:chunk)); mergingLatin = latin; offset += count
                if space { chunk += 1 }
            }
        }
    }
    if profile == .currentPlayer {
        var i = 0
        while i<atoms.count {
            guard isCJK(atoms[i].word.text), atoms[i].word.ruby.isEmpty else { i += 1; continue }
            let begin = i
            while i<atoms.count && isCJK(atoms[i].word.text) && atoms[i].word.ruby.isEmpty { i += 1 }
            let text = atoms[begin..<i].map { $0.word.text }.joined()
            let tokenizer = NLTokenizer(unit:.word); tokenizer.string = text
            var ai = begin
            tokenizer.enumerateTokens(in:text.startIndex..<text.endIndex) { range,_ in
                var n = text[range].utf16.count; chunk += 1
                while n>0 && ai<i { atoms[ai].chunk = chunk; n -= atoms[ai].word.text.utf16.count; ai += 1 }; return true
            }
        }
    }
    var i = 0
    while i<atoms.count {
        let start = i, key = atoms[i].chunk
        while i<atoms.count && atoms[i].chunk == key { i += 1 }
        let text = atoms[start..<i].map { $0.word.text }.joined().trimmingCharacters(in:.whitespacesAndNewlines)
        func qualifies(_ text: String, _ duration: Double) -> Bool {
            duration >= 1 && (isCJK(text) || (text.utf16.count>1 && text.utf16.count<=7))
        }
        let from = atoms[start..<i].map { $0.word.range.start }.min() ?? 0, to = atoms[start..<i].map { $0.word.range.end }.max() ?? 0
        let qualifiesChunk = atoms[start..<i].contains { qualifies($0.word.text,$0.word.range.duration) } || (!isCJK(text) && qualifies(text,to-from))
        if dynamic && qualifiesChunk {
            let characters = atoms[start..<i].reduce(0) { $0+$1.word.text.trimmingCharacters(in:.whitespacesAndNewlines).count }
            let ruby = atoms[start..<i].reduce(0) { $0+$1.word.ruby.reduce(0) { $0+$1.text.utf16.count } }
            let env = EmphasisEnvelope(start:from,duration:to-from,characters:characters,anchorCharacters:ruby>0 ? ruby : characters,isLast:text.contains(line.words.last?.text ?? ""),isBackground:line.isBackground,lineEnd:emphasisLineEnd)
            var offset = 0
            for j in start..<i { atoms[j].emphasis = env; atoms[j].characterOffset = offset; offset += atoms[j].word.text.trimmingCharacters(in:.whitespacesAndNewlines).count }
        }
    }
    return atoms
}

/// AMLL's balanced paragraph objective, using widths measured by Core Text.
func balancedBreaks(widths: [Double], texts: [String], width: Double) -> Set<Int> {
    let n = widths.count
    guard n>0, widths.reduce(0,+)>width else { return [] }
    var prefix = [0.0]; for w in widths { prefix.append(prefix.last!+w) }
    var costs = Array(repeating:Double.infinity,count:n+1), next = Array(repeating:n,count:n+1)
    costs[n] = 0
    let punctuation = CharacterSet(charactersIn:",.;:!?，。；：！？、）】》」』’”)]}>~…")
    for i in (0..<n).reversed() {
        for j in (i+1)...n {
            let w = prefix[j]-prefix[i]
            if w>width && j>i+1 { break }
            var cost = pow(width-w,2)*(w>width ? 1000 : 1)
            if j<n {
                let text = texts[j-1]
                if text.unicodeScalars.last.map({ punctuation.contains($0) }) == true { cost -= pow(width*0.6,2) }
                else if text.allSatisfy(\.isWhitespace) { cost -= pow(width*0.4,2) }
                else { cost += pow(width*(isCJK(texts[j]) ? 0.15 : 0.5),2) }
            }
            if cost+costs[j]<costs[i] { costs[i] = cost+costs[j]; next[i] = j }
        }
    }
    var result: Set<Int> = [], cursor = 0
    while cursor<n { cursor = next[cursor]; if cursor<n { result.insert(cursor) } }
    return result
}

struct MaskPath {
    struct Point { var time: Double; var position: Double }
    var points: [Point] = []
    private var anticipation: [Point] = []
    init(_ words: [WordPlacement], fadeWidth: Double) {
        // A flattened LRC/TTML line is often tokenized into several visual
        // words even though every token carries the same line-level range.
        // Treat that range as one authored sweep. Without this special case,
        // collapsing duplicate time knots leaves the cursor at the end of the
        // line on the very first sample (the one-word “good night” symptom).
        let spanWords = words.filter {
            !$0.atom.word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.atom.word.range.start.isFinite
                && $0.atom.word.range.end.isFinite
        }
        let singleTimedSpan: Bool = {
            guard let first = spanWords.first else { return false }
            let sharedRange = spanWords.allSatisfy {
                abs($0.atom.word.range.start - first.atom.word.range.start) < 0.001
                    && abs($0.atom.word.range.end - first.atom.word.range.end) < 0.001
            }
            // Timed ruby syllables are a real sub-word sweep even when the
            // base word itself has one line-level range. Preserve those knots.
            let rubyHasDistinctTiming = spanWords.contains { placement in
                placement.atom.word.ruby.contains {
                    abs($0.range.start - placement.atom.word.range.start) >= 0.001
                        || abs($0.range.end - placement.atom.word.range.end) >= 0.001
                }
            }
            return sharedRange && !rubyHasDistinctTiming
        }()
        var x = -2*fadeWidth
        points = [Point(time:words.first?.atom.word.range.start ?? 0,position:x)]
        for (i,placement) in words.enumerated() {
            var word = placement.atom.word
            if word.text.allSatisfy(\.isWhitespace) {
                let before = words.prefix(i).last(where: { !$0.atom.word.text.allSatisfy(\.isWhitespace) })?.atom.word.range.end
                let after = words.dropFirst(i+1).first(where: { !$0.atom.word.text.allSatisfy(\.isWhitespace) })?.atom.word.range.start
                let start = before ?? after ?? word.range.start
                word.range = LyricRange(start,max(start,after ?? start))
            }
            points.append(.init(time:word.range.start,position:x))
            let ruby = word.ruby.filter { !$0.text.isEmpty }
            if !ruby.isEmpty {
                let length = max(1,ruby.reduce(0) { $0+$1.text.utf16.count })
                for (j,r) in ruby.enumerated() {
                    points.append(.init(time:max(word.range.start,r.range.start),position:x))
                    x += placement.width*Double(r.text.utf16.count)/Double(length)
                    if i == 0 && j == 0 { x += fadeWidth*1.5 }
                    if i == words.count-1 && j == ruby.count-1 { x += fadeWidth*0.5 }
                    points.append(.init(time:min(word.range.end,max(r.range.start,r.range.end)),position:x))
                }
            } else {
                x += placement.width + (i == 0 ? fadeWidth*1.5 : 0) + (i == words.count-1 ? fadeWidth*0.5 : 0)
                points.append(.init(time:word.range.end,position:x))
            }
        }
        if singleTimedSpan,
           let first = spanWords.first,
           let last = points.last,
           first.atom.word.range.end > first.atom.word.range.start {
            points = [
                Point(time: first.atom.word.range.start, position: points.first?.position ?? -2 * fadeWidth),
                Point(time: first.atom.word.range.end, position: last.position)
            ]
        }
        // A malformed overlapping word must not reorder the spatial sweep.
        // Keep document order and clamp backwards timestamps to the last boundary.
        for i in points.indices.dropFirst() { points[i].time = max(points[i-1].time,points[i].time) }
        // Collapse duplicate time boundaries before constructing a continuous
        // forward corridor. Low-distance spans include timed whitespace: moving
        // only across a space looks frozen even though the cursor is advancing.
        var knots: [Point] = []
        for point in points {
            if knots.last?.time == point.time { knots[knots.count-1] = point }
            else { knots.append(point) }
        }
        anticipation = knots.map { Point(time:$0.time,position:0) }
        if knots.count > 2 {
            for i in 1..<(knots.count-1) {
                let a = knots[i-1], b = knots[i], next = knots[i+1]
                if b.time-a.time > 0.03 && b.position-a.position <= fadeWidth*0.7 {
                    anticipation[i].position = min(max(0,next.position-b.position)*0.12,fadeWidth*0.6)
                }
            }
        }
    }
    func anticipatedPosition(at time: Double, amount: Double) -> Double {
        let exact = position(at:time)
        guard amount > 0, let first = anticipation.first, time >= first.time else { return exact }
        var lo = 0, hi = anticipation.count
        while lo < hi { let m = (lo+hi)/2; if anticipation[m].time <= time { lo = m+1 } else { hi = m } }
        guard lo < anticipation.count else { return exact }
        let a = anticipation[max(0,lo-1)], b = anticipation[lo]
        let lead = a.position+(b.position-a.position)*Curves.clamp((time-a.time)/max(0.000001,b.time-a.time))
        return exact+lead*min(1,amount/0.12)
    }
    func position(at time: Double) -> Double {
        guard let first = points.first else { return 0 }
        if time<first.time { return first.position }
        var lo = 0, hi = points.count
        while lo<hi { let m = (lo+hi)/2; if points[m].time<=time { lo = m+1 } else { hi = m } }
        if lo>=points.count { return points.last!.position }
        let a = points[max(0,lo-1)], b = points[lo]
        return a.position+(b.position-a.position)*Curves.clamp((time-a.time)/max(0.000001,b.time-a.time))
    }
}
