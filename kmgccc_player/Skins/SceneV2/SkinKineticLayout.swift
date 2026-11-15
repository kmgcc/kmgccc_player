import Foundation
import NaturalLanguage

/// `kineticLayout(words, seed, avoid, width, height, advance, font, weight, energy, complexity)`
/// composes one lyric line as poster typography and returns where every word goes. Units: 100 is
/// one em of ordinary text; the skin multiplies by its own scale.
///
/// The line is cut into segments (a word, or a CJK token found by the system tokenizer). The
/// segment with the most text and time is the hero; segments held longer than the line's pace,
/// or picked at random on longer lines, become semi-heroes. A composition is then generated from
/// seeded choices: an archetype (rows, a hero on its own row, a vertical hero beside or between
/// the rows, an orbit, vertical columns, a cascade, an arc, a wave, a justified block, a collage,
/// a spiral, slanted rows, stepped vertical columns, plain calm rows for slow lines), then its row breaks, alignment, stairs,
/// vertical alignment, spacing, size contrast, tilt, and where and how each word enters. Rows
/// read top to bottom and left to right, so the line keeps its reading order; boxes are pushed
/// apart until none overlap and the whole is scaled to the safe area.
///
/// Arguments after `words`: `seed`, `avoid` (`family` values of recent lines, so a composition is
/// not repeated), `width` / `height` (safe area), `advance` (vertical glyph pitch in em), `font`
/// (one name, or `[latin, cjk]`), `weight`, `energy` (hero size, 1 is designed) and `complexity`
/// (0 simple: rows read left to right with an occasional vertical word; 1 rich: every archetype;
/// values between mix them, so a line or a song can be given its own).
/// Result: `family` (archetype × 1000 + variant), `archetype`, `hero` (item index), `size`
/// `[w, h]`, `ghost` `[x, y, scale]` (scale 0 for none), `ghostText`, and `items`, one per word:
/// `x`, `y` (centre), `s` (scale), `w`, `h`, `v` (1 for a stacked vertical word), `r` (degrees),
/// `ex`, `ey` (unit direction it comes from), `m` (how it enters: 0 slide, 1 zoom, 2 spin, 3 zip,
/// 4 fall), `role` (0 support, 1 semi-hero, 2 hero), `k`
/// (1 for CJK), `seg`, `t` (text to draw), `start`, `end`. A single word holding a whole line (a
/// line without word timing) is first spread over its tokens, so `items` may outnumber `words`.
@MainActor
enum SkinKineticLayout {
    enum Archetype: Int, CaseIterable {
        case rows, heroRow, side, pillar, orbit, columns, cascade, arc, single
        /// Along a gentle wave; rows scaled to one justified width; a loose collage on a grid;
        /// a spiral out from the hero; tilted rows; vertical columns stepping left to right.
        case wave, block, scatter, spiral, slant, steps
        /// Plain, even rows, centred or left aligned, for quiet and slow lines; likelier right
        /// after another calm line, so a quiet passage reads as one.
        case calm
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
        /// How the word enters: 0 slide, 1 zoom, 2 spin, 3 zip (glyphs from alternate sides), 4 fall.
        var mode = 0
        var tilt = 0.0
        var duration: Double { max(0, end - start) }
    }

    /// Seeded draws: each call returns the next value in 0..<1.
    private final class Draws {
        let seed: Double
        var count = 0.0
        init(_ seed: Double) { self.seed = seed }
        func next() -> Double {
            count += 1
            let value = sin(seed * 91.3458 + count * 47.123 + 0.5) * 43758.5453
            return value - floor(value)
        }
        func chance(_ p: Double) -> Bool { next() < p }
        func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
        func int(_ low: Int, _ high: Int) -> Int { high <= low ? low : low + min(high - low, Int(next() * Double(high - low + 1))) }
        func pick(_ weights: [Double]) -> Int {
            let total = weights.reduce(0, +)
            guard total > 0 else { return 0 }
            var value = next() * total
            for (index, weight) in weights.enumerated() {
                value -= weight
                if value <= 0, weight > 0 { return index }
            }
            return weights.lastIndex { $0 > 0 } ?? 0
        }
    }

    /// `options` are the function's arguments after `words`, in order.
    static func layout(_ words: [SkinValue], options: [SkinValue]) -> SkinValue {
        let words = Array(words.prefix(64))
        guard !words.isEmpty else { return .record(["items": .list([]), "family": .number(-1), "archetype": .number(-1), "hero": .number(-1), "size": .list([.number(0), .number(0)])]) }
        func option(_ index: Int) -> SkinValue { options.indices.contains(index) ? options[index] : .null }
        let seed = option(0).number()
        let avoid = Set(option(1).listValue.map { Int($0.number(-1)) })
        let safeW = max(200, option(2).number(1400))
        let safeH = max(150, option(3).number(800))
        let advance = max(0.8, option(4).number(1.08))
        let fonts = option(5).type == .list ? option(5).listValue.map(\.textValue) : [option(5).textValue]
        let latinFont = fonts.first ?? "", cjkFont = fonts.count > 1 ? fonts[1] : latinFont
        let weight = option(6).textValue.isEmpty ? "heavy" : option(6).textValue
        let energy = max(0, min(2, option(7).number(1)))
        let complexity = option(8).type == .null ? 1 : max(0, min(1, option(8).number(1)))
        let draws = Draws(seed)

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
        let widths = inked.map { SkinTextMeasure.width($0, size: 100, weight: weight, font: $0.contains(where: isCJK) ? cjkFont : latinFont) }

        var parts = segment(texts: texts, inked: inked, widths: widths, starts: starts, ends: ends)
        let n = parts.count
        let totalChars = max(1, parts.reduce(0) { $0 + $1.chars })
        let cjkChars = parts.reduce(0) { $0 + ($1.cjk ? $1.chars : 0) }
        let cjkLine = cjkChars * 2 >= totalChars
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
        let jitter = parts.indices.map { _ in draws.next() * 24 }
        candidates.sort { score(parts[$0]) + (held(parts[$0]) ? 40 : 0) + jitter[$0] > score(parts[$1]) + (held(parts[$1]) ? 40 : 0) + jitter[$1] }
        var semis: [Int] = []
        for index in candidates where semis.count < semiLimit && semis.allSatisfy({ abs($0 - index) >= 2 }) { semis.append(index) }
        let spare = parts.indices.filter { $0 != hero && parts[$0].wordLike && abs($0 - hero) >= 2 }
        if semis.isEmpty, n >= 3, draws.chance(0.4), !spare.isEmpty {
            semis.append(spare[min(spare.count - 1, Int(draws.next() * Double(spare.count)))])
        }
        semis.forEach { parts[$0].role = 1 }

        // Archetype. Specials are never repeated within two lines; rows only grow less likely.
        let gap = cjkLine ? 16.0 : 32.0
        let plainWidth = parts.reduce(0) { $0 + $1.width } + gap * Double(max(0, n - 1))
        let wide = plainWidth / safeW
        let c = complexity
        let heroCJK = parts[hero].cjk && parts[hero].chars >= 2 && parts[hero].chars <= 8
        let avoided = Set(avoid.map { $0 >= 0 ? $0 / 1000 : -1 })
        var weights = [Double](repeating: 0, count: Archetype.allCases.count)
        if n == 1 {
            weights[Archetype.single.rawValue] = 1
        } else {
            weights[Archetype.rows.rawValue] = 3
            weights[Archetype.heroRow.rawValue] = 2.4
            weights[Archetype.side.rawValue] = heroCJK ? 0.35 + 1.2 * c : (parts[hero].chars >= 3 && !parts[hero].cjk ? 0.6 * c : 0)
            weights[Archetype.pillar.rawValue] = heroCJK && hero > 0 && hero < n - 1 ? 1.3 * c : 0
            weights[Archetype.orbit.rawValue] = (3...8).contains(n) && pace >= 0.22 ? 1.4 * c : 0
            weights[Archetype.columns.rawValue] = cjkLine && totalChars <= 22 ? 1.2 * c : 0
            weights[Archetype.cascade.rawValue] = (2...6).contains(n) ? 0.15 + 1.0 * c : 0
            weights[Archetype.arc.rawValue] = (3...9).contains(n) && wide < 2.4 ? 1.1 * c : 0
            weights[Archetype.wave.rawValue] = (3...10).contains(n) && wide < 3 ? 1.1 * c : 0
            weights[Archetype.block.rawValue] = (2...8).contains(n) ? 0.5 + 1.0 * c : 0
            weights[Archetype.scatter.rawValue] = (3...12).contains(n) ? 1.2 * c : 0
            weights[Archetype.spiral.rawValue] = (4...10).contains(n) ? 0.9 * c : 0
            weights[Archetype.slant.rawValue] = 0.9 * c
            weights[Archetype.steps.rawValue] = cjkLine && (2...7).contains(n) && totalChars <= 18 ? 1.1 * c : 0
            // Slow singing (long per character) reads as a quiet line.
            let slow = min(1, max(0, (perChar - (cjkLine ? 0.28 : 0.18)) / 0.25))
            weights[Archetype.calm.rawValue] = 0.35 + 1.6 * slow
            for archetype in Archetype.allCases where avoided.contains(archetype.rawValue) {
                switch archetype {
                case .calm: weights[archetype.rawValue] *= 2.2
                case .rows, .heroRow, .block: weights[archetype.rawValue] *= 0.45
                default: weights[archetype.rawValue] = 0
                }
            }
            if weights.allSatisfy({ $0 <= 0 }) { weights[Archetype.rows.rawValue] = 1 }
        }
        let archetype = Archetype(rawValue: draws.pick(weights)) ?? .rows

        // Size contrast. Rich lines reach further in both directions.
        let growthRange: (Double, Double)
        switch archetype {
        case .rows, .slant: growthRange = (1.0 + 0.3 * c, 1.7 + 0.6 * c)
        case .heroRow: growthRange = (1.5, 2.3 + 0.5 * c)
        case .side, .pillar: growthRange = (1.6, 2.2)
        case .orbit, .spiral: growthRange = (1.4, 2.0)
        case .columns, .steps: growthRange = (0.9, 1.5)
        case .cascade, .arc, .wave: growthRange = (0.9, 1.5)
        case .single: growthRange = (1.6, 2.1)
        case .block: growthRange = (0.4, 0.9)
        case .scatter: growthRange = (1.2, 2.0 + 0.4 * c)
        case .calm: growthRange = (0.08, 0.25)
        }
        // A long Latin hero grows less: a word is far wider than a CJK character of the same size.
        let heroDamp = parts[hero].cjk ? 1 : (parts[hero].chars > 7 ? 0.55 : (parts[hero].chars > 4 ? 0.75 : 0.9))
        let heroScale = 1 + draws.range(growthRange.0, growthRange.1) * energy * heroDamp
        let semiScale = 1 + (heroScale - 1) * draws.range(0.3, 0.5)
        // Supports: flat, a little uneven, swelling toward the hero, alternating, or tapering.
        let scheme = archetype == .calm ? 0 : draws.pick([1, 1 + c, 0.8 * c, 0.6 * c, 0.6 * c])
        let kicker = archetype == .heroRow && hero > 0 && draws.chance(0.5)
        for index in parts.indices {
            switch parts[index].role {
            case 2: parts[index].scale = heroScale
            case 1: parts[index].scale = semiScale
            default:
                var s = 1.0
                switch scheme {
                case 1: s = 1 + (draws.next() - 0.5) * (0.1 + 0.16 * c)
                case 2: s = 0.86 + 0.28 * (1 - min(1, Double(abs(index - hero)) / 4))
                case 3: s = index % 2 == 0 ? 1 : 0.82
                case 4: s = 1.1 - 0.25 * Double(index) / Double(max(1, n - 1))
                default: break
                }
                // A collage mixes sizes freely.
                if archetype == .scatter { s *= draws.range(0.7, 1.5) }
                if kicker && index < hero { s *= 0.78 }
                parts[index].scale = s
            }
            // Latin sits a little smaller than CJK at the same size.
            if !parts[index].cjk { parts[index].scale *= 0.8 }
        }

        // Orientation, then box sizes. Simple lines keep words upright except a rare vertical hero.
        let verticalHero = (archetype == .side || archetype == .pillar) || (archetype == .single && heroCJK && draws.chance(0.12 + 0.25 * c))
        let verticalSemi = [.rows, .heroRow].contains(archetype) && draws.chance(0.06 + 0.2 * c)
        for index in parts.indices {
            var stacked = archetype == .columns || (archetype == .steps && parts[index].chars > 1)
            if index == hero && verticalHero { stacked = true }
            if parts[index].role == 1 && verticalSemi && parts[index].cjk && (2...5).contains(parts[index].chars) { stacked = true }
            // A collage turns the odd support word on its side.
            if archetype == .scatter, index != hero, parts[index].chars > 1, draws.chance(0.18) { stacked = true }
            if stacked {
                if parts[index].cjk { parts[index].vertical = true }
                else if parts[index].chars > 1, archetype != .columns { parts[index].rotated = true }
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

        let variant = compose(&parts, archetype: archetype, hero: hero, gap: gap, safeW: safeW, safeH: safeH,
                              complexity: c, avoid: avoid, draws: draws)

        // Fit the whole composition (tilted boxes counted by their rotated extent) and centre it.
        func extent(_ part: Segment) -> (Double, Double) {
            let angle = abs(part.tilt) * .pi / 180
            return (part.w * cos(angle) + part.h * sin(angle), part.h * cos(angle) + part.w * sin(angle))
        }
        let minX = parts.map { $0.x - extent($0).0 / 2 }.min() ?? 0, maxX = parts.map { $0.x + extent($0).0 / 2 }.max() ?? 0
        let minY = parts.map { $0.y - extent($0).1 / 2 }.min() ?? 0, maxY = parts.map { $0.y + extent($0).1 / 2 }.max() ?? 0
        let fit = max(0.45, min(1, safeW / max(1, maxX - minX), safeH / max(1, maxY - minY)))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        for index in parts.indices {
            parts[index].x = (parts[index].x - cx) * fit
            parts[index].y = (parts[index].y - cy) * fit
            parts[index].scale *= fit
            parts[index].w *= fit
            parts[index].h *= fit
        }

        // Words inside their segments, laid along the segment's own axis and tilt.
        var items: [SkinValue] = []
        for (number, part) in parts.enumerated() {
            let along = part.vertical || part.rotated
            var cursor = along ? -part.h / 2 : -part.w / 2
            let angle = part.tilt * .pi / 180
            for index in part.first...part.last {
                let s = part.scale
                let text = inked[index]
                var dx = 0.0, dy = 0.0, w = widths[index] * s, h = 102 * s, shown = text
                if part.vertical {
                    let glyphs = text.filter { !$0.isWhitespace }
                    h = Double(max(1, glyphs.count)) * advance * 100 * s
                    w = 100 * s
                    dy = cursor + h / 2
                    cursor += h
                    shown = glyphs.map(String.init).joined(separator: "\n")
                } else if part.rotated {
                    dy = cursor + w / 2
                    cursor += w
                    swap(&w, &h)
                } else {
                    dx = cursor + w / 2
                    cursor += w
                }
                let x = part.x + dx * cos(angle) - dy * sin(angle), y = part.y + dx * sin(angle) + dy * cos(angle)
                items.append(.record([
                    "x": .number(x), "y": .number(y), "s": .number(s), "w": .number(w), "h": .number(h),
                    "v": .number(part.vertical ? 1 : 0), "r": .number((part.rotated ? 90 : 0) + part.tilt),
                    "ex": .number(part.ex), "ey": .number(part.ey), "m": .number(Double(part.mode)), "role": .number(Double(part.role)),
                    "k": .number(part.cjk ? 1 : 0), "seg": .number(Double(number)), "t": .text(shown),
                    "start": .number(starts[index]), "end": .number(ends[index]),
                ]))
            }
        }

        let ghostArchetypes: Set<Archetype> = [.rows, .heroRow, .side, .pillar, .orbit, .cascade, .spiral, .slant, .steps]
        let hasGhost = ghostArchetypes.contains(archetype) && parts[hero].chars <= 6 && draws.chance(0.6)
        let ghostScale = hasGhost ? min(5, max(2.6, parts[hero].scale * 1.7)) : 0
        let ghostSide = draws.chance(0.5) ? -1.0 : 1.0
        let ghost: [SkinValue] = [.number(parts[hero].x - safeW * 0.1 * ghostSide), .number(parts[hero].y - safeH * 0.06), .number(ghostScale)]
        return .record([
            "family": .number(Double(archetype.rawValue * 1000 + variant)), "archetype": .number(Double(archetype.rawValue)),
            "hero": .number(Double(parts[hero].first)),
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

    // MARK: Composition

    /// Places every segment for `archetype` and sets where each enters from. Returns the variant
    /// number (0…999) that, with the archetype, names the composition for `avoid`.
    private static func compose(_ parts: inout [Segment], archetype: Archetype, hero: Int, gap baseGap: Double,
                                safeW: Double, safeH: Double, complexity c: Double, avoid: Set<Int>, draws: Draws) -> Int {
        let n = parts.count
        let all = Array(0..<n)
        let before = Array(0..<hero), after = Array((hero + 1)..<n)
        let gap = baseGap * draws.range(0.75, 1.1 + 0.5 * c)
        let leading = 36 * draws.range(0.3, 0.6 + 0.5 * c)

        // Row style: alignment 0 left, 1 centre, 2 right, 3 justified; vertical alignment 0
        // bottom, 1 centre, 2 top, 3 staggered; stairs and zigzag offsets per row.
        var align = 0, valign = 0, stairs = 0.0, zig = 0.0, pattern = 0, extraRows = 0
        var signature = 0
        for _ in 0..<4 {
            align = draws.pick([1.2, 1.4, 0.4 + 0.6 * c, 0.5 + 0.5 * c])
            valign = draws.pick([1.6, 0.8, 0.3 + 0.5 * c, 0.6 * c])
            stairs = draws.chance(0.12 + 0.35 * c) ? (draws.chance(0.7 - 0.3 * c) ? 1 : -1) * safeW * draws.range(0.04, 0.06 + 0.1 * c) : 0
            zig = stairs == 0 && draws.chance(0.25 * c) ? safeW * draws.range(0.04, 0.12) : 0
            pattern = draws.pick([1.5, 0.8 + 0.4 * c, 0.6 + 0.4 * c, 0.6 * c])
            extraRows = draws.pick([1.4, 1, 0.8 * c])
            signature = align + 4 * valign + 16 * (stairs > 0 ? 1 : (stairs < 0 ? 2 : 0)) + 48 * (zig > 0 ? 1 : 0) + 96 * pattern + 384 * extraRows
            if !avoid.contains(archetype.rawValue * 1000 + signature) { break }
        }

        /// Splits `indices` into `count` rows by width, the rows' shares following `pattern`
        /// (even, growing, shrinking, uneven). Every row keeps at least one segment.
        func breakRows(_ indices: [Int], count: Int) -> [[Int]] {
            let count = max(1, min(indices.count, count))
            guard count > 1 else { return [indices] }
            var shares = (0..<count).map { row -> Double in
                switch pattern {
                case 1: 1 + Double(row) * 0.6
                case 2: 1 + Double(count - 1 - row) * 0.6
                case 3: 0.6 + draws.next()
                default: 1
                }
            }
            let total = shares.reduce(0, +)
            shares = shares.map { $0 / total }
            let widths = indices.map { parts[$0].w }
            let sum = widths.reduce(0, +) + gap * Double(indices.count - 1)
            var rows: [[Int]] = [[]], used = 0.0, boundary = shares[0] * sum
            for (position, index) in indices.enumerated() {
                let remainingItems = indices.count - position
                let remainingRows = count - rows.count
                let middle = used + widths[position] / 2
                if !rows[rows.count - 1].isEmpty, remainingRows > 0, (middle > boundary || remainingItems <= remainingRows) {
                    rows.append([])
                    boundary += shares[rows.count - 1] * sum
                }
                rows[rows.count - 1].append(index)
                used += widths[position] + gap
            }
            return rows
        }

        func rowCount(_ indices: [Int], measure: Double) -> Int {
            guard !indices.isEmpty else { return 0 }
            let width = indices.reduce(0) { $0 + parts[$1].w } + gap * Double(indices.count - 1)
            let least = max(1, Int(ceil(width / measure)))
            return min(indices.count, least + extraRows)
        }

        /// Lays `rows` top to bottom from `top`, each row left to right. Returns the block's bottom.
        @discardableResult
        func layRows(_ rows: [[Int]], left: Double, top: Double, align: Int) -> Double {
            let rowWidths = rows.map { row in row.reduce(0) { $0 + parts[$1].w } + gap * Double(max(0, row.count - 1)) }
            let block = rowWidths.max() ?? 0
            var y = top
            for (number, row) in rows.enumerated() where !row.isEmpty {
                let height = row.map { parts[$0].h }.max() ?? 0
                var spacing = gap
                var x = left
                switch align {
                case 1: x += (block - rowWidths[number]) / 2
                case 2: x += block - rowWidths[number]
                case 3:
                    if row.count > 1 { spacing = gap + (block - rowWidths[number]) / Double(row.count - 1) }
                    else { x += (block - rowWidths[number]) / 2 }
                default: break
                }
                x += Double(number) * stairs + (number % 2 == 0 ? 0 : zig)
                for (order, index) in row.enumerated() {
                    parts[index].x = x + parts[index].w / 2
                    switch valign {
                    case 1: parts[index].y = y + height / 2
                    case 2: parts[index].y = y + parts[index].h / 2
                    case 3: parts[index].y = y + height - parts[index].h / 2 - (order % 2 == 0 ? 0 : min(height - parts[index].h, parts[index].h * 0.22))
                    default: parts[index].y = y + height - parts[index].h / 2
                    }
                    x += parts[index].w + spacing
                }
                y += height + leading
            }
            return y - leading
        }

        let measure = safeW * draws.range(0.55, 0.95)
        var resolves = true
        switch archetype {
        case .calm:
            // Even rows broken by width alone: no stairs, zigzag, stagger or extra rows.
            stairs = 0; zig = 0; valign = 1; pattern = 0; extraRows = 0
            align = draws.chance(0.6) ? 1 : 0
            signature = align
            layRows(breakRows(all, count: rowCount(all, measure: safeW * 0.72)), left: 0, top: 0, align: align)
        case .rows:
            layRows(breakRows(all, count: rowCount(all, measure: measure)), left: 0, top: 0, align: align)
        case .heroRow:
            var y = 0.0
            if !before.isEmpty {
                y = layRows(breakRows(before, count: rowCount(before, measure: measure)), left: 0, top: 0, align: align) + leading * 1.3
            }
            layRows([[hero]], left: 0, top: y, align: align)
            y = parts[hero].y + parts[hero].h / 2 + leading * 1.3
            if !after.isEmpty { layRows(breakRows(after, count: rowCount(after, measure: measure)), left: 0, top: y, align: align) }
            // Rows share one left edge or centre line with the hero row.
            let anchor = align == 2 ? parts[hero].x + parts[hero].w / 2 : (align == 0 ? parts[hero].x - parts[hero].w / 2 : parts[hero].x)
            for group in [before, after] where !group.isEmpty {
                let lo = group.map { parts[$0].x - parts[$0].w / 2 }.min() ?? 0, hi = group.map { parts[$0].x + parts[$0].w / 2 }.max() ?? 0
                let edge = align == 2 ? hi : (align == 0 ? lo : (lo + hi) / 2)
                for index in group { parts[index].x += anchor - edge }
            }
        case .side, .pillar:
            let heroBox = parts[hero]
            let rowHeight = (parts.filter { $0.role != 2 }.map(\.h).max() ?? 102) + leading
            let others = before + after
            let lines = max(1, min(others.count, Int((heroBox.h / rowHeight).rounded())))
            if archetype == .side {
                // The vertical hero stands on the side its place in the line suggests.
                let heroLeft = hero <= (n - 1) / 2
                let rows = breakRows(others, count: lines)
                let bottom = layRows(rows, left: 0, top: 0, align: heroLeft ? 0 : 2)
                let blockW = others.map { parts[$0].x + parts[$0].w / 2 }.max() ?? 0
                let place = draws.pick([1, 1, 0.8])
                let dy = place == 0 ? -heroBox.h / 2 : (place == 1 ? -bottom / 2 : heroBox.h / 2 - bottom)
                for index in others {
                    parts[index].x += heroLeft ? heroBox.w / 2 + gap * 1.5 : -(blockW + heroBox.w / 2 + gap * 1.5)
                    parts[index].y += dy
                }
            } else {
                let leftRows = breakRows(before, count: max(1, lines / 2))
                let rightRows = breakRows(after, count: max(1, lines / 2))
                let leftBottom = layRows(leftRows, left: 0, top: 0, align: 2)
                let leftW = before.map { parts[$0].x + parts[$0].w / 2 }.max() ?? 0
                for index in before { parts[index].x += -leftW - heroBox.w / 2 - gap * 1.5; parts[index].y += -heroBox.h / 2 }
                let rightBottom = layRows(rightRows, left: 0, top: 0, align: 0)
                let diagonal = draws.chance(0.6)
                for index in after {
                    parts[index].x += heroBox.w / 2 + gap * 1.5
                    parts[index].y += diagonal ? heroBox.h / 2 - rightBottom : -heroBox.h / 2 + max(0, leftBottom - rightBottom) / 2
                }
            }
            parts[hero].x = 0; parts[hero].y = 0
        case .orbit:
            resolves = false
            let heroBox = parts[hero]
            let others = before + after
            let widest = others.map { parts[$0].w }.max() ?? 0, tallest = others.map { parts[$0].h }.max() ?? 0
            var rx = heroBox.w / 2 + widest / 2 + gap * 1.5, ry = heroBox.h / 2 + tallest / 2 + 22
            let span = min(5.4, 1.15 * Double(others.count))
            let begin = -2.6 + (draws.next() - 0.5) * 0.6
            let tilts = others.map { _ in (draws.next() - 0.5) * 8 }
            parts[hero].x = 0; parts[hero].y = 0
            for _ in 0..<6 {
                for (order, index) in others.enumerated() {
                    let angle = begin + span * (others.count > 1 ? Double(order) / Double(others.count - 1) : 0.5)
                    var x = cos(angle) * rx, y = sin(angle) * ry
                    // Off the axes an ellipse cuts into the hero's box; push out along the ray.
                    let clearX = (heroBox.w + parts[index].w) / 2 + gap, clearY = (heroBox.h + parts[index].h) / 2 + 11
                    if abs(x) < clearX, abs(y) < clearY {
                        let push = min(abs(x) > 0.001 ? clearX / abs(x) : .infinity, abs(y) > 0.001 ? clearY / abs(y) : .infinity)
                        if push.isFinite { x *= push; y *= push }
                    }
                    parts[index].x = x; parts[index].y = y
                    parts[index].tilt = tilts[order]
                }
                let crowded = zip(others, others.dropFirst()).contains { a, b in
                    abs(parts[a].x - parts[b].x) < (parts[a].w + parts[b].w) / 2 && abs(parts[a].y - parts[b].y) < (parts[a].h + parts[b].h) / 2
                }
                if !crowded { break }
                rx *= 1.18; ry *= 1.12
            }
        case .columns:
            // Top to bottom, columns from right to left.
            let cap = max(parts[hero].h, safeH * draws.range(0.6, 0.9))
            let drop = draws.chance(0.5) ? draws.range(20, 60) : 0
            var x = 0.0, y = 0.0, columnWidth = 0.0, column = 0
            for index in all {
                if y > 0, y + parts[index].h > cap {
                    x -= columnWidth + gap * 1.6; y = 0; columnWidth = 0; column += 1
                }
                parts[index].x = x - parts[index].w / 2
                parts[index].y = Double(column) * drop + y + parts[index].h / 2
                y += parts[index].h + 11
                columnWidth = max(columnWidth, parts[index].w)
            }
        case .cascade:
            var y = 0.0
            let step = draws.range(0.35, 0.65) * (parts.map(\.w).reduce(0, +) / Double(n))
            for index in all {
                parts[index].x = Double(index) * step + parts[index].w / 2
                parts[index].y = y + parts[index].h / 2
                y += parts[index].h + leading * 0.4
            }
        case .arc:
            resolves = false
            let spacing = gap * 1.3
            let length = all.reduce(0) { $0 + parts[$1].w } + spacing * Double(n - 1)
            let sweep = draws.range(0.55, 0.9 + 0.3 * c)
            let radius = length / sweep
            let arch = draws.chance(0.55)
            var cursor = -length / 2
            for index in all {
                let phi = (cursor + parts[index].w / 2) / radius
                parts[index].x = radius * sin(phi)
                parts[index].y = (arch ? 1 : -1) * radius * (1 - cos(phi))
                parts[index].tilt = (arch ? 1 : -1) * phi * 180 / .pi
                cursor += parts[index].w + spacing
            }
        case .single:
            parts[hero].x = 0; parts[hero].y = 0
            if !parts[hero].vertical, draws.chance(0.35 * c) { parts[hero].tilt = (draws.next() - 0.5) * 10 }
        case .wave:
            resolves = false
            // A sine baseline whose steepest slope stays under 0.35, each word turned to it.
            let tallest = all.map { parts[$0].h }.max() ?? 102
            var spacing = gap * 1.3 + 0.12 * tallest
            let turns = draws.range(0.6, 1.3), share = draws.range(0.5, 1)
            let phase = draws.range(0, 2 * .pi)
            // Neighbours turned to different slopes can touch at a corner; open the spacing until none do.
            for _ in 0..<8 {
                let length = all.reduce(0) { $0 + parts[$1].w } + spacing * Double(n - 1)
                let k = 2 * .pi * turns / max(1, length)
                let amplitude = 0.35 / k * share
                var cursor = -length / 2
                for index in all {
                    let x = cursor + parts[index].w / 2
                    parts[index].x = x
                    parts[index].y = amplitude * sin(k * x + phase)
                    parts[index].tilt = atan(amplitude * k * cos(k * x + phase)) * 180 / .pi
                    cursor += parts[index].w + spacing
                }
                if !zip(all, all.dropFirst()).contains(where: { overlaps(parts[$0], parts[$1], margin: 6) }) { break }
                spacing *= 1.35
            }
        case .block:
            // Rows scaled up or down to one width, so the line reads as a justified block.
            let count = max(2, min(min(n, 5), Int((Double(n) / draws.range(1.2, 2.4)).rounded())))
            let rows = breakRows(all, count: count)
            let natural = rows.map { row in row.reduce(0) { $0 + parts[$1].w } }
            let target = (natural.max() ?? 1) * draws.range(0.85, 1.1)
            for (number, row) in rows.enumerated() {
                let room = target - gap * Double(max(0, row.count - 1))
                let factor = min(3.2, max(0.55, room / max(1, natural[number])))
                for index in row {
                    parts[index].scale *= factor; parts[index].w *= factor; parts[index].h *= factor
                }
            }
            layRows(rows, left: 0, top: 0, align: draws.chance(0.7) ? 3 : 1)
        case .scatter:
            // A loose grid read left to right, top to bottom; each word nudged off its cell.
            let columns = n <= 4 ? 2 : (n <= 9 ? 3 : 4)
            let cellW = (parts.map(\.w).max() ?? 100) * draws.range(0.75, 1.0) + gap
            let cellH = (parts.map(\.h).max() ?? 102) * draws.range(0.7, 0.95) + leading
            for (order, index) in all.enumerated() {
                let column = order % columns, row = order / columns
                parts[index].x = Double(column) * cellW + (draws.next() - 0.5) * cellW * 0.4
                parts[index].y = Double(row) * cellH + (draws.next() - 0.5) * cellH * 0.45
                if !parts[index].vertical, !parts[index].rotated, draws.chance(0.4) { parts[index].tilt = (draws.next() - 0.5) * 12 }
            }
        case .spiral:
            // Out from the hero along an Archimedean spiral; turns sit one word height apart.
            let heroBox = parts[hero]
            let others = before + after
            let tallest = others.map { parts[$0].h }.max() ?? 102
            let pitch = (tallest + 34) / (2 * .pi)
            let turn = draws.chance(0.5) ? 1.0 : -1.0
            var theta = draws.range(0, 2 * .pi)
            var radius = hypot(heroBox.w, heroBox.h) / 2 + tallest / 2 + 20
            parts[hero].x = 0; parts[hero].y = 0
            for (order, index) in others.enumerated() {
                parts[index].x = cos(theta) * radius * 1.25
                parts[index].y = sin(theta) * radius
                if order + 1 < others.count {
                    let step = (parts[index].w + parts[others[order + 1]].w) / 2 + gap * 1.5
                    let dTheta = step / max(radius, 1)
                    theta += turn * dTheta
                    radius += pitch * dTheta
                }
            }
        case .slant:
            layRows(breakRows(all, count: rowCount(all, measure: measure)), left: 0, top: 0, align: align)
        case .steps:
            // Vertical columns left to right, each starting a step lower (or higher) than the last.
            let step = (parts.map(\.h).reduce(0, +) / Double(n)) * draws.range(0.18, 0.45) * (draws.chance(0.75) ? 1 : -1)
            let swing = draws.chance(0.3) ? draws.range(30, 80) : 0
            var x = 0.0
            for (order, index) in all.enumerated() {
                parts[index].x = x + parts[index].w / 2
                parts[index].y = Double(order) * step + parts[index].h / 2 + (order % 2 == 0 ? 0 : swing)
                x += parts[index].w + gap * 1.6
            }
        }

        // Rows-like compositions: push later boxes away from earlier ones until none overlap.
        if resolves {
            // A tilted box counts by its turned extent.
            func extent(_ part: Segment) -> (w: Double, h: Double) {
                let angle = abs(part.tilt) * .pi / 180
                return (part.w * cos(angle) + part.h * sin(angle), part.h * cos(angle) + part.w * sin(angle))
            }
            for _ in 0..<60 {
                var moved = false
                for i in parts.indices {
                    for j in parts.indices where j > i {
                        let dx = parts[j].x - parts[i].x, dy = parts[j].y - parts[i].y
                        let a = extent(parts[i]), b = extent(parts[j])
                        let overlapX = (a.w + b.w) / 2 + gap * 0.5 - abs(dx)
                        let overlapY = (a.h + b.h) / 2 + 8 - abs(dy)
                        guard overlapX > 0, overlapY > 0 else { continue }
                        if overlapX < overlapY { parts[j].x += (dx >= 0 ? 1 : -1) * overlapX }
                        else { parts[j].y += (dy >= 0 ? 1 : -1) * overlapY }
                        moved = true
                    }
                }
                if !moved { break }
            }
        }

        // A slight tilt of the whole composition on rich lines; a slant turns it clearly.
        let slant = archetype == .slant
        if slant || ([.rows, .heroRow, .cascade, .block].contains(archetype) && draws.chance(0.3 * c)) {
            let angle = (slant ? (draws.chance(0.5) ? 1 : -1) * draws.range(10, 22) : (draws.next() - 0.5) * 8) * .pi / 180
            for index in parts.indices {
                let x = parts[index].x, y = parts[index].y
                parts[index].x = x * cos(angle) - y * sin(angle)
                parts[index].y = x * sin(angle) + y * cos(angle)
                parts[index].tilt += angle * 180 / .pi
            }
        }

        enter(&parts, archetype: archetype, hero: hero, align: align, complexity: c, draws: draws)
        return signature
    }

    /// Whether two boxes, each turned by its tilt, come within `margin` of each other.
    private static func overlaps(_ a: Segment, _ b: Segment, margin: Double) -> Bool {
        func corners(_ part: Segment) -> [(Double, Double)] {
            let angle = part.tilt * .pi / 180, hw = part.w / 2 + margin / 2, hh = part.h / 2 + margin / 2
            return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { dx, dy in
                (part.x + dx * cos(angle) - dy * sin(angle), part.y + dx * sin(angle) + dy * cos(angle))
            }
        }
        let p = corners(a), q = corners(b)
        for shape in [p, q] {
            for i in 0..<4 {
                let axis = (-(shape[(i + 1) % 4].1 - shape[i].1), shape[(i + 1) % 4].0 - shape[i].0)
                let first = p.map { $0.0 * axis.0 + $0.1 * axis.1 }, second = q.map { $0.0 * axis.0 + $0.1 * axis.1 }
                if first.max()! <= second.min()! || second.max()! <= first.min()! { return false }
            }
        }
        return true
    }

    /// Where each word comes from, and how. A line has one way in: along the reading direction,
    /// rising, dropping, from the side its row is aligned to, alternating by row, or out of the
    /// centre; specials enter along their own shape. Some words then break away (out of the
    /// centre, from their nearest side, or the opposite way), every direction is turned a little,
    /// and each word draws its own manner: slide, zoom, spin, zip or fall.
    private static func enter(_ parts: inout [Segment], archetype: Archetype, hero: Int, align: Int, complexity c: Double, draws: Draws) {
        func set(_ index: Int, _ x: Double, _ y: Double) {
            let length = hypot(x, y)
            guard length > 0.0001 else { parts[index].ex = 0; parts[index].ey = 1; return }
            parts[index].ex = x / length; parts[index].ey = y / length
        }
        let cx = parts.map(\.x).reduce(0, +) / Double(parts.count), cy = parts.map(\.y).reduce(0, +) / Double(parts.count)
        var shaped = true
        switch archetype {
        case .orbit, .spiral:
            let inward = draws.chance(0.5)
            for index in parts.indices where index != hero {
                set(index, (parts[index].x - cx) * (inward ? 1 : -1), (parts[index].y - cy) * (inward ? 1 : -1))
            }
            set(hero, 0, 1)
        case .columns:
            for index in parts.indices { set(index, 0, -1) }
        case .cascade:
            for index in parts.indices { set(index, -0.8, -0.6) }
        case .arc, .wave:
            // Along the curve, as if the line were drawn from its start.
            for index in parts.indices {
                let angle = parts[index].tilt * .pi / 180
                set(index, -cos(angle), -sin(angle))
            }
        case .steps:
            // Columns drop in and rise in by turns.
            for index in parts.indices { set(index, 0, index % 2 == 0 ? -1 : 1) }
        case .calm:
            // Quiet lines rise gently and slide, nothing more.
            for index in parts.indices {
                let turn = (draws.next() - 0.5) * 0.2
                set(index, sin(turn), cos(turn))
                parts[index].mode = 0
            }
            return
        default:
            shaped = false
        }
        if !shaped {
            let mode = draws.pick([1.4, 1.2, 0.4 + 0.5 * c, 0.8, 0.6 * c, 0.6 * c])
            // Rows, by their vertical position, for the alternating mode.
            let rowKeys = Array(Set(parts.map { ($0.y / 40).rounded() })).sorted()
            for index in parts.indices {
                let part = parts[index]
                switch mode {
                case 0: set(index, -1, 0.15)
                case 1: set(index, 0, 1)
                case 2: set(index, 0, -1)
                case 3:
                    if part.vertical { set(index, 0, -1) }
                    else { set(index, align == 0 ? -1 : (align == 2 ? 1 : 0), align == 1 || align == 3 ? 1 : 0.1) }
                case 4:
                    let row = rowKeys.firstIndex(of: (part.y / 40).rounded()) ?? 0
                    set(index, row % 2 == 0 ? -1 : 1, 0.1)
                default:
                    set(index, part.x - cx, part.y - cy)
                }
                if part.vertical && mode != 5 { set(index, 0, -1) }
            }
            if mode != 5 { set(hero, parts[hero].ex * 0.5, parts[hero].ey * 0.5 + 0.5) }
        }

        let breakaway = (shaped ? 0.12 : 0.22) + (shaped ? 0.18 : 0.33) * c
        for index in parts.indices {
            let part = parts[index]
            if parts.count > 1, draws.chance(breakaway) {
                switch draws.pick([1, 1, 0.8, 0.6]) {
                case 0: set(index, part.x - cx, part.y - cy)
                case 1: set(index, part.x >= cx ? 1 : -1, (draws.next() - 0.5) * 0.4)
                case 2: set(index, (draws.next() - 0.5) * 0.4, part.y >= cy ? 1 : -1)
                default: set(index, -part.ex, -part.ey)
                }
            }
            let turn = (draws.next() - 0.5) * (0.3 + 0.5 * c)
            let ex = parts[index].ex, ey = parts[index].ey
            set(index, ex * cos(turn) - ey * sin(turn), ex * sin(turn) + ey * cos(turn))
            // Chinese leans to the quiet manners; rich lines use all five.
            let weights: [Double] = part.cjk
                ? [2, 0.5 + 0.6 * c, 0.15 + 0.45 * c, 0.3 + 0.4 * c, 0.3 * c]
                : [1.6, 0.5 + 0.6 * c, 0.2 + 0.7 * c, 0.4 * c, 0.4 * c]
            parts[index].mode = index == hero && draws.chance(0.35) ? 1 : draws.pick(weights)
        }
    }
}
