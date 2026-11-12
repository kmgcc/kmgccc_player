import Foundation
import NaturalLanguage

/// `kineticLayout(words, seed, avoid, width, height, advance, font, weight, energy)` composes one
/// lyric line as poster typography and returns where every word goes. Units: 100 is one em of ordinary text; the skin multiplies by its own scale.
///
/// The line is cut into segments (a word, or a CJK token found by the system tokenizer). The
/// segment with the most text and time is the hero; segments held longer than the line's pace,
/// or picked at random on longer lines, become semi-heroes. A composition is then chosen from the
/// line's shape (segment count, width, script, pace) with seeded weights, never one listed in
/// `avoid`, laid out on measured boxes and scaled as a whole to the safe area.
///
/// Arguments after `words`: `seed`, `avoid` (families to skip), `width` / `height` (safe area),
/// `advance` (vertical glyph pitch in em), `font`, `weight`, `energy` (hero size, 1 is designed).
/// Result: `family`, `hero` (item index), `size` `[w, h]`, `ghost` `[x, y, scale]` (scale 0 for
/// none), `ghostText`, and `items`, one per word: `x`, `y` (centre), `s` (scale), `w`, `h`,
/// `v` (1 for a stacked vertical word), `r` (degrees), `ex`, `ey` (unit direction it comes from),
/// `role` (0 support, 1 semi-hero, 2 hero), `seg`, `t` (text to draw), `start`, `end`.
/// A single word holding a whole line (a line without word timing) is first spread over its
/// tokens, so `items` may outnumber `words`.
@MainActor
enum SkinKineticLayout {
    enum Family: Int, CaseIterable {
        case ribbon, tableau, pillar, header, stairs, badge, orbit, impact, flow, columns, cascade
    }

    private struct Segment {
        var first: Int, last: Int
        var text: String
        var width: Double
        var chars: Int
        var start: Double, end: Double
        var cjk: Bool
        var wordLike: Bool
        var role = 0
        var scale = 1.0
        var vertical = false, rotated = false
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        var ex = 0.0, ey = 1.0
        var tilt = 0.0
        var duration: Double { max(0, end - start) }
    }

    /// `options` are the function's arguments after `words`, in order.
    static func layout(_ words: [SkinValue], options: [SkinValue]) -> SkinValue {
        let words = Array(words.prefix(64))
        guard !words.isEmpty else { return .record(["items": .list([]), "family": .number(-1), "hero": .number(-1), "size": .list([.number(0), .number(0)])]) }
        func option(_ index: Int) -> SkinValue { options.indices.contains(index) ? options[index] : .null }
        let seed = option(0).number()
        let avoid = Set(option(1).listValue.map { Int($0.number(-1)) })
        let safeW = max(200, option(2).number(1400))
        let safeH = max(150, option(3).number(800))
        let advance = max(0.8, option(4).number(1.08))
        let font = option(5).textValue
        let weight = option(6).textValue.isEmpty ? "heavy" : option(6).textValue
        let energy = max(0, min(2, option(7).number(1)))
        func random(_ salt: Double) -> Double {
            let value = sin(seed * 91.3458 + salt * 47.123 + 0.5) * 43758.5453
            return value - floor(value)
        }

        // Words and their inked widths at size 100, trailing spaces excluded.
        var texts = words.map { $0.type == .record ? $0[member: "text"].textValue : $0.textValue }
        var starts = words.map { $0[member: "start"].number() }
        var ends = words.enumerated().map { max(starts[$0.offset], $0.element[member: "end"].number(starts[$0.offset])) }
        // A line without word timing arrives as one word; spread it over its tokens by length.
        if texts.count == 1 {
            let tokens = spread(texts[0])
            if tokens.count > 1 {
                let weights = tokens.map { Double(max(1, $0.filter { !$0.isWhitespace }.count)) }
                let total = weights.reduce(0, +), span = ends[0] - starts[0], begin = starts[0]
                var offset = 0.0
                texts = tokens; starts = []; ends = []
                for weight in weights {
                    starts.append(begin + span * offset / total)
                    offset += weight
                    ends.append(begin + span * offset / total)
                }
            }
        }
        let inked = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let widths = inked.map { SkinTextMeasure.width($0, size: 100, weight: weight, font: font) }

        let segments = segment(texts: texts, inked: inked, widths: widths, starts: starts, ends: ends)
        var parts = segments
        let n = parts.count
        let totalChars = max(1, parts.reduce(0) { $0 + $1.chars })
        let cjkChars = parts.reduce(0) { $0 + ($1.cjk ? $1.chars : 0) }
        let cjkLine = cjkChars * 2 >= totalChars
        let gap = cjkLine ? 16.0 : 32.0, stack = 36.0
        let lineSpan = max(0.1, (ends.max() ?? 0) - (starts.min() ?? 0))
        let pace = lineSpan / Double(n)

        // Roles: the hero, then semi-heroes held longer than the line's pace or picked at random.
        func score(_ part: Segment) -> Double { Double(min(part.chars, 8)) * 14 + min(2.5, part.duration) * 18 }
        let hero = parts.indices.filter { parts[$0].wordLike }.max { score(parts[$0]) < score(parts[$1]) } ?? 0
        parts[hero].role = 2
        let perChar = lineSpan / Double(totalChars)
        let semiLimit = n < 3 ? 0 : (n <= 5 ? 1 : (n <= 10 ? 2 : 3))
        let held: (Segment) -> Bool = { $0.duration >= 0.45 && $0.duration / Double(max(1, $0.chars)) >= perChar * 1.8 }
        var candidates = parts.indices.filter { index in
            index != hero && parts[index].wordLike && abs(index - hero) >= (n <= 4 ? 1 : 2)
                && (score(parts[index]) >= score(parts[hero]) * 0.35 || held(parts[index]))
        }
        candidates.sort { score(parts[$0]) + (held(parts[$0]) ? 40 : 0) + random(Double($0) * 3.1) * 24
            > score(parts[$1]) + (held(parts[$1]) ? 40 : 0) + random(Double($1) * 3.1) * 24 }
        var semis: [Int] = []
        for index in candidates where semis.count < semiLimit && semis.allSatisfy({ abs($0 - index) >= 2 }) { semis.append(index) }
        let spare = parts.indices.filter { $0 != hero && parts[$0].wordLike && abs($0 - hero) >= 2 }
        if semis.isEmpty, n >= 3, random(7.7) < 0.4, !spare.isEmpty {
            semis.append(spare[min(spare.count - 1, Int(random(8.8) * Double(spare.count)))])
        }
        semis.forEach { parts[$0].role = 1 }

        // Composition by the line's shape.
        let plainWidth = parts.reduce(0) { $0 + $1.width } + gap * Double(max(0, n - 1))
        let wide = plainWidth / safeW
        var weights: [Family: Double] = [:]
        switch n {
        case 1:
            weights = [.impact: 3, .columns: cjkLine && totalChars >= 2 ? 2 : 0, .ribbon: 1]
        case 2...3:
            weights = [.impact: 2.5, .tableau: 2, .ribbon: wide < 1.3 ? 2 : 0.5, .cascade: n == 3 ? 1.5 : 0.5,
                       .pillar: cjkLine ? 2 : 1, .columns: cjkLine ? 1.6 : 0, .orbit: n == 3 ? 1 : 0]
        case 4...6:
            weights = [.ribbon: wide < 1.2 ? 1.5 : 0.3, .tableau: 2, .pillar: cjkLine ? 2 : 0.8, .header: 2, .stairs: 2,
                       .orbit: 2, .cascade: 1.5, .badge: n >= 5 ? 1.2 : 0.4, .columns: cjkLine && totalChars <= 18 ? 1.6 : 0, .impact: 0.8]
        case 7...10:
            weights = [.header: 1.5, .stairs: 2, .badge: 2, .flow: 2.5, .orbit: n <= 8 ? 1.2 : 0,
                       .columns: cjkLine && totalChars <= 22 ? 1.2 : 0, .tableau: n <= 8 ? 1 : 0, .pillar: cjkLine ? 1 : 0]
        default:
            weights = [.flow: 3, .badge: 2, .stairs: 1.5, .header: 1]
        }
        if pace < 0.28 {
            weights[.orbit] = (weights[.orbit] ?? 0) * 0.5
            weights[.columns] = (weights[.columns] ?? 0) * 0.6
            weights[.flow] = (weights[.flow] ?? 0) + 0.8
        }
        let pool = Family.allCases.filter { (weights[$0] ?? 0) > 0 && !avoid.contains($0.rawValue) }
        let usable = pool.isEmpty ? Family.allCases.filter { (weights[$0] ?? 0) > 0 } : pool
        let total = usable.reduce(0) { $0 + (weights[$1] ?? 0) }
        var pick = random(1.3) * total
        var family = usable.first ?? .impact
        for candidate in usable {
            pick -= weights[candidate] ?? 0
            if pick <= 0 { family = candidate; break }
        }

        // Scales.
        let designed: [Family: Double] = [.ribbon: 2.7, .tableau: 2.5, .pillar: 3.0, .header: 2.7, .stairs: 2.2, .badge: 3.1,
                                          .orbit: 2.6, .impact: 3.6, .flow: 1.8, .columns: 2.2, .cascade: 2.1]
        let heroScale = 1 + ((designed[family] ?? 2.4) - 1) * energy * (0.9 + 0.2 * random(2.9)) * (n == 1 ? 0.75 : 1)
        let semiScale = 1 + (heroScale - 1) * 0.42
        let jitters = family == .orbit || family == .cascade || family == .flow
        for index in parts.indices {
            parts[index].scale = parts[index].role == 2 ? heroScale : (parts[index].role == 1 ? semiScale : (jitters ? 0.88 + 0.24 * random(Double(index) * 1.7) : 1))
        }

        // Orientation, then box sizes.
        for index in parts.indices {
            let stacked: Bool
            switch family {
            case .columns: stacked = true
            case .pillar, .badge: stacked = index == hero
            default: stacked = false
            }
            if stacked {
                if parts[index].cjk { parts[index].vertical = true } else if parts[index].chars > 1 { parts[index].rotated = true }
            }
            let s = parts[index].scale
            if parts[index].vertical {
                parts[index].w = 100 * s
                parts[index].h = Double(max(1, parts[index].chars)) * advance * 100 * s
            } else if parts[index].rotated {
                parts[index].w = 102 * s
                parts[index].h = parts[index].width * s
            } else {
                parts[index].w = parts[index].width * s
                parts[index].h = 102 * s
            }
        }

        let variant = Int(random(4.1) * 4)
        let mirror = random(5.3) < 0.5
        place(&parts, family: family, hero: hero, variant: variant, mirror: mirror, gap: gap, stack: stack, safeW: safeW, safeH: safeH, random: random)

        // Fit the whole composition and centre it.
        let minX = parts.map { $0.x - $0.w / 2 }.min() ?? 0, maxX = parts.map { $0.x + $0.w / 2 }.max() ?? 0
        let minY = parts.map { $0.y - $0.h / 2 }.min() ?? 0, maxY = parts.map { $0.y + $0.h / 2 }.max() ?? 0
        let fit = max(0.5, min(1, safeW / max(1, maxX - minX), safeH / max(1, maxY - minY)))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        for index in parts.indices {
            parts[index].x = (parts[index].x - cx) * fit
            parts[index].y = (parts[index].y - cy) * fit
            parts[index].scale *= fit
            parts[index].w *= fit
            parts[index].h *= fit
        }

        // Words inside their segments.
        var items: [SkinValue] = []
        for (number, part) in parts.enumerated() {
            var cursor = part.vertical || part.rotated ? part.y - part.h / 2 : part.x - part.w / 2
            for index in part.first...part.last {
                let s = part.scale
                let text = inked[index]
                var x = part.x, y = part.y, w = widths[index] * s, h = 102 * s, shown = text
                if part.vertical {
                    let glyphs = text.filter { !$0.isWhitespace }
                    h = Double(max(1, glyphs.count)) * advance * 100 * s
                    w = 100 * s
                    y = cursor + h / 2
                    cursor += h
                    shown = glyphs.map(String.init).joined(separator: "\n")
                } else if part.rotated {
                    y = cursor + w / 2
                    cursor += w
                    swap(&w, &h)
                } else {
                    x = cursor + w / 2
                    cursor += w
                }
                items.append(.record([
                    "x": .number(x), "y": .number(y), "s": .number(s), "w": .number(w), "h": .number(h),
                    "v": .number(part.vertical ? 1 : 0), "r": .number((part.rotated ? 90 : 0) + part.tilt),
                    "ex": .number(part.ex), "ey": .number(part.ey), "role": .number(Double(part.role)),
                    "seg": .number(Double(number)), "t": .text(shown),
                    "start": .number(starts[index]), "end": .number(ends[index]),
                ]))
            }
        }

        let ghostFamilies: Set<Family> = [.ribbon, .tableau, .pillar, .header, .orbit, .stairs, .cascade]
        let hasGhost = ghostFamilies.contains(family) && parts[hero].chars <= 6 && random(6.1) < 0.7
        let ghostScale = hasGhost ? min(5, max(2.6, parts[hero].scale * 1.7)) : 0
        let ghost: [SkinValue] = [.number(parts[hero].x - safeW * 0.1 * (mirror ? -1 : 1)), .number(parts[hero].y - safeH * 0.06), .number(ghostScale)]
        return .record([
            "family": .number(Double(family.rawValue)), "hero": .number(Double(parts[hero].first)),
            "size": .list([.number((maxX - minX) * fit), .number((maxY - minY) * fit)]),
            "ghost": .list(ghost), "ghostText": .text(parts[hero].text),
            "items": .list(items),
        ])
    }

    // MARK: Segments

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) }
    }

    /// CJK per character, other text per word with its trailing space; punctuation stays attached.
    private static func spread(_ text: String) -> [String] {
        var tokens: [String] = [], current = "", inWord = false
        for character in text {
            if character.isWhitespace {
                if !current.isEmpty { current.append(character) }
                inWord = false
            } else if character.isPunctuation, !current.isEmpty {
                current.append(character)
            } else if inWord, !isCJK(character) {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(character)
                inWord = !isCJK(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return Array(tokens.prefix(64))
    }

    private static func segment(texts: [String], inked: [String], widths: [Double], starts: [Double], ends: [Double]) -> [Segment] {
        let joined = texts.joined()
        var tokenStarts = Set<Int>()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = joined
        tokenizer.enumerateTokens(in: joined.startIndex..<joined.endIndex) { range, _ in
            tokenStarts.insert(joined.distance(from: joined.startIndex, to: range.lowerBound))
            return true
        }
        var result: [Segment] = []
        var offset = 0
        for index in texts.indices {
            let text = texts[index], ink = inked[index]
            let cjk = ink.contains(where: isCJK)
            let punctuation = !ink.isEmpty && ink.allSatisfy { $0.isPunctuation || $0.isSymbol }
            let chars = ink.filter { !$0.isWhitespace && !$0.isPunctuation }.count
            var begins = true
            if let last = result.last, index > 0 {
                let spaced = texts[index - 1].last?.isWhitespace == true || text.first?.isWhitespace == true
                if punctuation || ink.isEmpty { begins = false }
                else if spaced { begins = true }
                else if cjk && last.cjk { begins = tokenStarts.contains(offset) || last.chars >= 4 }
                else { begins = cjk != last.cjk }
            }
            offset += text.count
            if begins {
                result.append(Segment(first: index, last: index, text: ink, width: widths[index], chars: chars,
                                      start: starts[index], end: ends[index], cjk: cjk, wordLike: ink.contains { $0.isLetter }))
            } else {
                result[result.count - 1].last = index
                result[result.count - 1].text += ink
                result[result.count - 1].width += widths[index]
                result[result.count - 1].chars += chars
                result[result.count - 1].end = max(result[result.count - 1].end, ends[index])
                result[result.count - 1].wordLike = result[result.count - 1].wordLike || ink.contains { $0.isLetter }
            }
        }
        return result
    }

    // MARK: Compositions

    private static func place(_ parts: inout [Segment], family: Family, hero: Int, variant: Int, mirror: Bool,
                              gap: Double, stack: Double, safeW: Double, safeH: Double, random: (Double) -> Double) {
        let n = parts.count
        let side = mirror ? -1.0 : 1.0
        parts[hero].x = 0; parts[hero].y = 0; parts[hero].ex = 0; parts[hero].ey = 1

        /// Lays `indices` left to right in rows no wider than `limit`, from (`left`, `top`).
        /// `align` 0 left, 1 centre, 2 right. Returns the bottom edge.
        func rows(_ indices: [Int], left: Double, top: Double, limit: Double, align: Int, enter: (Double, Double)) -> Double {
            var lines: [[Int]] = [[]], widths: [Double] = [0]
            for index in indices {
                let extra = (lines[lines.count - 1].isEmpty ? 0 : gap) + parts[index].w
                if !lines[lines.count - 1].isEmpty && widths[widths.count - 1] + extra > limit {
                    lines.append([]); widths.append(0)
                }
                widths[widths.count - 1] += (lines[lines.count - 1].isEmpty ? 0 : gap) + parts[index].w
                lines[lines.count - 1].append(index)
            }
            var y = top
            for (line, width) in zip(lines, widths) where !line.isEmpty {
                let height = line.map { parts[$0].h }.max() ?? 0
                var x = left + (align == 1 ? (limit - width) / 2 : (align == 2 ? limit - width : 0))
                for index in line {
                    parts[index].x = x + parts[index].w / 2
                    parts[index].y = y + height - parts[index].h / 2
                    parts[index].ex = enter.0; parts[index].ey = enter.1
                    x += parts[index].w + gap
                }
                y += height + stack * 0.55
            }
            return y - stack * 0.55
        }

        let before = Array(0..<hero), after = Array((hero + 1)..<n)
        let others = before + after
        let heroBox = parts[hero]
        switch family {
        case .ribbon:
            var x = -heroBox.w / 2 - gap
            for index in before.reversed() {
                parts[index].x = x - parts[index].w / 2; x -= parts[index].w + gap
                parts[index].ex = 1; parts[index].ey = 0
            }
            x = heroBox.w / 2 + gap
            for index in after {
                parts[index].x = x + parts[index].w / 2; x += parts[index].w + gap
                parts[index].ex = -1; parts[index].ey = 0
            }
            for (order, index) in others.enumerated() {
                switch variant % 3 {
                case 0: parts[index].y = heroBox.h / 2 - parts[index].h / 2 - heroBox.h * 0.08
                case 1: parts[index].y = -heroBox.h / 2 + parts[index].h / 2 + heroBox.h * 0.06
                default: parts[index].y = (order % 2 == 0 ? -1 : 1) * heroBox.h * 0.26
                }
            }
        case .tableau:
            var y = -heroBox.h / 2 - stack * 0.5
            for index in before.reversed() {
                parts[index].y = y - parts[index].h / 2; y -= parts[index].h + stack * 0.5
                parts[index].ex = 0; parts[index].ey = -1
            }
            y = heroBox.h / 2 + stack * 0.5
            for index in after {
                parts[index].y = y + parts[index].h / 2; y += parts[index].h + stack * 0.5
                parts[index].ex = 0; parts[index].ey = 1
            }
            for (order, index) in others.enumerated() {
                switch variant {
                case 0: parts[index].x = 0
                case 1: parts[index].x = -heroBox.w / 2 + parts[index].w / 2
                case 2: parts[index].x = heroBox.w / 2 - parts[index].w / 2
                default: parts[index].x = (order % 2 == 0 ? -1 : 1) * min(heroBox.w * 0.3, 120)
                }
            }
        case .pillar:
            let top = -heroBox.h / 2
            var y = top
            for index in before {
                parts[index].x = side * (heroBox.w / 2 + gap * 1.5 + parts[index].w / 2)
                parts[index].y = y + parts[index].h / 2; y += parts[index].h + stack * 0.4
                parts[index].ex = -side; parts[index].ey = 0
            }
            y = top + (variant % 2 == 0 ? 0 : heroBox.h * 0.3)
            for index in after {
                parts[index].x = -side * (heroBox.w / 2 + gap * 1.5 + parts[index].w / 2)
                parts[index].y = y + parts[index].h / 2; y += parts[index].h + stack * 0.4
                parts[index].ex = side; parts[index].ey = 0
            }
        case .header:
            let kickerWidth = max(heroBox.w * 1.3, safeW * 0.4)
            if !before.isEmpty {
                let bottom = rows(before, left: -kickerWidth / 2, top: 0, limit: kickerWidth, align: 1, enter: (0, -1))
                let lift = bottom + stack * 0.6 + heroBox.h / 2
                before.forEach { parts[$0].y -= lift }
            }
            let leftAnchor = -heroBox.w * 0.25 - gap / 2, rightAnchor = heroBox.w * 0.25 + gap / 2
            var y = heroBox.h / 2 + stack * 0.6
            var pair = 0
            while pair < after.count {
                let left = after[pair], right = pair + 1 < after.count ? after[pair + 1] : nil
                let height = max(parts[left].h, right.map { parts[$0].h } ?? 0)
                parts[left].x = leftAnchor - parts[left].w / 2; parts[left].y = y + height - parts[left].h / 2
                parts[left].ex = -1; parts[left].ey = 0
                if let right {
                    parts[right].x = rightAnchor + parts[right].w / 2; parts[right].y = y + height - parts[right].h / 2
                    parts[right].ex = 1; parts[right].ey = 0
                }
                y += height + stack * 0.5
                pair += 2
            }
        case .stairs, .flow:
            let limit = family == .flow ? safeW * (0.62 + 0.2 * random(8.2)) : max(heroBox.w * 1.2, safeW * 0.5)
            let align = family == .flow ? variant % 3 : 0
            _ = rows(Array(0..<n), left: -limit / 2, top: 0, limit: limit, align: align, enter: (0, 1))
            if family == .stairs {
                // Each row steps further in, like a staircase.
                let rowsY = Array(Set(parts.map { ($0.y + $0.h / 2).rounded() })).sorted()
                for index in parts.indices {
                    let row = rowsY.firstIndex(of: (parts[index].y + parts[index].h / 2).rounded()) ?? 0
                    parts[index].x += side * Double(row) * safeW * (0.07 + 0.04 * random(9.4))
                    parts[index].ex = -side; parts[index].ey = 0
                }
            }
        case .badge:
            let pillarRight = heroBox.w / 2
            let rowHeight = 102.0 + stack * 0.55
            let lines = max(1, (heroBox.h / rowHeight).rounded())
            let othersWidth = others.reduce(0) { $0 + parts[$1].w + gap }
            let widest = others.map { parts[$0].w }.max() ?? 0
            let limit = max(widest, min(safeW * 0.55, othersWidth / lines * 1.1))
            _ = rows(others, left: pillarRight + gap * 1.5, top: -heroBox.h / 2, limit: limit, align: 0, enter: (-1, 0))
            if mirror {
                for index in others { parts[index].x = -parts[index].x; parts[index].ex = 1 }
            }
        case .orbit:
            let widest = others.map { parts[$0].w }.max() ?? 0, tallest = others.map { parts[$0].h }.max() ?? 0
            var rx = heroBox.w / 2 + widest / 2 + gap * 1.5, ry = heroBox.h / 2 + tallest / 2 + stack * 0.6
            let span = min(5.4, 1.15 * Double(others.count))
            let begin = -2.6 + (random(3.7) - 0.5) * 0.6
            for _ in 0..<5 {
                for (order, index) in others.enumerated() {
                    let angle = begin + span * (others.count > 1 ? Double(order) / Double(others.count - 1) : 0.5)
                    var x = cos(angle) * rx, y = sin(angle) * ry
                    // Off the axes an ellipse cuts into the hero's box; push out along the ray
                    // until the word clears it on one axis.
                    let clearX = (heroBox.w + parts[index].w) / 2 + gap, clearY = (heroBox.h + parts[index].h) / 2 + stack * 0.3
                    if abs(x) < clearX, abs(y) < clearY {
                        let push = min(abs(x) > 0.001 ? clearX / abs(x) : .infinity, abs(y) > 0.001 ? clearY / abs(y) : .infinity)
                        if push.isFinite { x *= push; y *= push }
                    }
                    parts[index].x = x
                    parts[index].y = y
                    parts[index].ex = cos(angle); parts[index].ey = sin(angle)
                    parts[index].tilt = (random(Double(index) * 2.3) - 0.5) * 8
                }
                let crowded = zip(others, others.dropFirst()).contains { a, b in
                    abs(parts[a].x - parts[b].x) < (parts[a].w + parts[b].w) / 2 && abs(parts[a].y - parts[b].y) < (parts[a].h + parts[b].h) / 2
                }
                if !crowded { break }
                rx *= 1.18; ry *= 1.12
            }
        case .impact:
            let limit = max(heroBox.w, safeW * 0.6)
            if !before.isEmpty {
                let bottom = rows(before, left: -limit / 2, top: 0, limit: limit, align: 1, enter: (0, -1))
                before.forEach { parts[$0].y -= bottom + stack * 0.5 + heroBox.h / 2 }
            }
            if !after.isEmpty {
                _ = rows(after, left: -limit / 2, top: heroBox.h / 2 + stack * 0.5, limit: limit, align: 1, enter: (0, 1))
            }
        case .columns:
            // Top to bottom, columns from right to left.
            let cap = max(heroBox.h, safeH * 0.85)
            var x = 0.0, y = 0.0, columnWidth = 0.0, column = 0
            for index in 0..<n {
                if y > 0, y + parts[index].h > cap {
                    x -= columnWidth + gap * 1.6; y = 0; columnWidth = 0; column += 1
                }
                let drop = variant % 2 == 1 ? Double(column) * 40 : 0
                parts[index].x = x - parts[index].w / 2
                parts[index].y = drop + y + parts[index].h / 2
                parts[index].ex = 0; parts[index].ey = -1
                y += parts[index].h + stack * 0.3
                columnWidth = max(columnWidth, parts[index].w)
            }
            if variant >= 2 {
                for index in 0..<n { parts[index].tilt = (random(Double(index) * 1.9) - 0.5) * 4 }
            }
        case .cascade:
            var y = 0.0
            let step = (0.35 + 0.3 * random(4.9)) * (parts.map(\.w).reduce(0, +) / Double(n))
            for index in 0..<n {
                parts[index].x = side * Double(index) * step + parts[index].w / 2 * side
                parts[index].y = y + parts[index].h / 2
                parts[index].ex = -side * 0.8; parts[index].ey = -0.6
                y += parts[index].h + stack * 0.35
            }
        }
    }
}
