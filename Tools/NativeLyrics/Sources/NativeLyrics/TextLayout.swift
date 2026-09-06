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

    private func font(_ config: LyricsConfiguration, size: Double) -> CTFont {
        let font = NSFont(name:config.fontName,size:size) ?? NSFont.systemFont(ofSize:size,weight:.semibold)
        let descriptor = font.fontDescriptor.addingAttributes([.traits:[NSFontDescriptor.TraitKey.weight:config.fontWeight]])
        let resolved = NSFont(descriptor:descriptor,size:size) ?? font
        return (config.fontWeight >= 0.23 ? NSFontManager.shared.convert(resolved,toHaveTrait:.boldFontMask) : resolved) as CTFont
    }
    static func shape(_ text: String, font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):true]))
    }
    static func width(_ text: String, font: CTFont) -> Double { CTLineGetTypographicBounds(shape(text,font:font),nil,nil,nil) }

    private func select(_ layers: [LyricTextLayer], language: String) -> LyricTextLayer? {
        layers.first { $0.language == language } ?? layers.first { !language.isEmpty && $0.language.hasPrefix(language.split(separator:"-").first.map(String.init) ?? language) } ?? layers.first
    }

    private func line(_ original: LyricLine, width: Double, config: LyricsConfiguration, dynamic: Bool, fontSize: Double) -> LineTextLayout {
        var line = original
        let mainFont = font(config,size:fontSize), smallFont = font(config,size:max(10,fontSize*0.5))
        let product = config.profile == .currentPlayer && config.surface != .coreReference
        var subConfig = config; subConfig.fontName = config.translationFontName; subConfig.fontWeight = config.translationFontWeight
        let subSize = max(6,config.translationFontSize ?? (product ? config.fontSize*0.75 : fontSize*0.5))
        let subFont = font(subConfig,size:subSize)
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
            let base = Self.width(atom.word.text,font:mainFont)
            let ruby = Self.width(atom.word.ruby.map(\.text).joined(),font:smallFont)
            let roman = Self.width(atom.word.romanization,font:smallFont) + (hasRoman ? fontSize*0.15 : 0)
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
                let baseWidth = Self.width(text,font:mainFont)
                let baseX = max(0,(w-baseWidth)/2)
                let mainY = hasRuby ? fontSize*0.5 : 0
                var pieces: [GlyphPlacement] = []
                if atom.emphasis != nil && config.emphasis {
                    var cx = baseX
                    for (j,ch) in text.enumerated() {
                        let cw = Self.width(String(ch),font:mainFont)
                        pieces.append(.init(text:String(ch),origin:CGPoint(x:cx,y:mainY),width:cw,font:mainFont,characterIndex:atom.characterOffset+j)); cx += cw
                    }
                } else {
                    pieces.append(.init(text:text,origin:CGPoint(x:baseX,y:mainY),width:baseWidth,font:mainFont))
                }
                if hasRuby {
                    let text = atom.word.ruby.map(\.text).joined(), rw = Self.width(text,font:smallFont)
                    if !text.isEmpty { pieces.append(.init(text:text,origin:CGPoint(x:(w-rw)/2,y:0),width:rw,font:smallFont)) }
                }
                if hasRoman, !atom.word.romanization.isEmpty {
                    let text = atom.word.romanization, rw = Self.width(text,font:smallFont)
                    pieces.append(.init(text:text,origin:CGPoint(x:(w-rw)/2,y:mainY+fontSize*1.2),width:rw,font:smallFont))
                }
                if w > width {
                    // Keep glyph identity/time; split at grapheme boundaries without dropping content.
                    var cx = 0.0, cy = 0.0
                    pieces = []
                    for (j,ch) in text.enumerated() {
                        let cw = Self.width(String(ch),font:mainFont)
                        if cx+cw>width && cx>0 { cx = 0; cy += rowHeight }
                        pieces.append(.init(text:String(ch),origin:CGPoint(x:cx,y:cy+mainY),width:cw,font:mainFont,characterIndex:atom.emphasis == nil ? nil : atom.characterOffset+j)); cx += cw
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
            let string = NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):subFont])
            let typesetter = CTTypesetterCreateWithAttributedString(string)
            var offset = 0
            while offset<string.length {
                let count = max(1,CTTypesetterSuggestLineBreak(typesetter,offset,width))
                let s = (text as NSString).substring(with:NSRange(location:offset,length:min(count,string.length-offset)))
                let w = Self.width(s,font:subFont)
                sublines.append(.init(text:s,origin:CGPoint(x:line.isDuet ? max(0,width-w) : 0,y:y),width:w,font:subFont))
                offset += count; y += subSize*(product ? 1.42 : 1.5)
            }
        }
        if config.showTranslation { append(select(line.translations,language:config.translationLanguage)?.text ?? "") }
        if let roman, roman.words.isEmpty { append(roman.text) }
        return LineTextLayout(words:words,sublines:sublines,height:max(fontSize*1.2,y),width:width,fontSize:fontSize,isDynamic:dynamic)
    }
}

private func isCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
}

func makeAtoms(_ line: LyricLine, profile: LyricsProfile, dynamic: Bool) -> [TextAtom] {
    var atoms: [TextAtom] = [], chunk = 0, mergingLatin = false
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
            let env = EmphasisEnvelope(start:from,duration:to-from,characters:characters,anchorCharacters:ruby>0 ? ruby : characters,isLast:text.contains(line.words.last?.text ?? ""),isBackground:line.isBackground)
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
    init(_ words: [WordPlacement], fadeWidth: Double) {
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
        // A malformed overlapping word must not reorder the spatial sweep.
        // Keep document order and clamp backwards timestamps to the last boundary.
        for i in points.indices.dropFirst() { points[i].time = max(points[i-1].time,points[i].time) }
    }
    func anticipatedPosition(at time: Double, amount: Double) -> Double {
        let exact = position(at:time)
        guard amount > 0, let first = points.first, time >= first.time else { return exact }
        for i in points.indices.dropFirst() {
            let a = points[i-1], b = points[i]
            if time >= a.time && time < b.time && a.position == b.position,
               let next = points.dropFirst(i+1).first(where: { $0.position > b.position }) {
                let lead = min((next.position-b.position)*0.08,amount*12)
                return exact + lead * (time-a.time)/max(0.001,b.time-a.time)
            }
            if time >= a.time && time < b.time && b.position > a.position && i >= 2 {
                let previous = points[i-2]
                if previous.position == a.position && previous.time < a.time {
                    let lead = min((b.position-a.position)*0.08,amount*12)
                    return exact + lead * (1-(time-a.time)/max(0.001,b.time-a.time))
                }
            }
        }
        return exact
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
