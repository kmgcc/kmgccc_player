import Foundation

struct PreparedGroup {
    var source: LyricGroup
    var main: LyricLine
    var background: LyricLine?
    var range: LyricRange { main.range }
    var backgroundFirst: Bool { (background?.words.first?.range.start ?? .infinity) < (main.words.first?.range.start ?? main.range.start) }
}

enum TimingPolicy {
    private enum FlatSlot {
        case main
        case background
    }

    /// AMLL receives a flat stream (main line followed by its optional
    /// background line), while the native model keeps that pair on one
    /// `LyricGroup`. Keeping preprocessing flat preserves the main→background
    /// adjacency used by syncing, overlap cleaning, and the reverse pass.
    private struct FlatLine {
        let groupIndex: Int
        let slot: FlatSlot
        var line: LyricLine
    }

    static func prepare(_ document: LyricsDocument, _ config: LyricsConfiguration) -> [PreparedGroup] {
        let timing = config.timing
        var groups = document.groups.map { source -> PreparedGroup in
            var main = source.main, bg = source.background
            // The app adapter passes the established combined track/global
            // visual offset, whose public contract is ±20 seconds. Keep the
            // wider bound here so extreme (but valid) per-track corrections
            // are not silently clipped back to the old ±15-second track-only
            // limit.
            let offset = min(20,max(-20,timing.trackOffset-timing.globalAdvance))
            func shifted(_ line: inout LyricLine) {
                line.range.start = max(0,line.range.start+offset); line.range.end = max(line.range.start,line.range.end+offset)
                for i in line.words.indices {
                    line.words[i].range.start = max(0,line.words[i].range.start+offset)
                    line.words[i].range.end = max(line.words[i].range.start,line.words[i].range.end+offset)
                    for j in line.words[i].ruby.indices {
                        line.words[i].ruby[j].range.start = max(0,line.words[i].ruby[j].range.start+offset)
                        line.words[i].ruby[j].range.end = max(line.words[i].ruby[j].range.start,line.words[i].ruby[j].range.end+offset)
                    }
                }
            }
            shifted(&main); if bg != nil { shifted(&bg!) }
            normalizeLineWordsAndBounds(&main)
            if bg != nil { normalizeLineWordsAndBounds(&bg!) }
            return PreparedGroup(source:source,main:main,background:bg)
        }
        // Stable order is important for equal-start duet groups and seek reconstruction.
        groups = groups.enumerated().sorted { a,b in a.element.range.start == b.element.range.start ? a.offset < b.offset : a.element.range.start < b.element.range.start }.map(\.element)

        // AMLL receives a flat stream (main followed by its optional
        // background), while the native model keeps that pair on one group.
        // Run the timing preprocessor on the equivalent flat stream so a
        // background row can never be mistaken for the next foreground row.
        var flat: [FlatLine] = []
        for groupIndex in groups.indices {
            flat.append(FlatLine(groupIndex: groupIndex, slot: .main, line: groups[groupIndex].main))
            if let background = groups[groupIndex].background {
                flat.append(FlatLine(groupIndex: groupIndex, slot: .background, line: background))
            }
        }
        convertExcessiveBackgroundLines(&flat)
        syncMainAndBackgroundTimes(&flat)
        cleanUnintentionalLineOverlaps(&flat)

        guard timing.enabled, !flat.isEmpty else {
            restore(flat, into: &groups)
            return groups
        }
        if config.profile == .upstream {
            // Upstream advance: bounded by the union of the preceding overlap group.
            var previous: LyricRange?; var union = LyricRange(0,0)
            for i in flat.indices where !flat[i].line.isBackground {
                let raw = flat[i].line.range
                let overlaps = previous.map { raw.start < $0.end } ?? false
                let amount = overlaps ? 0.4 : 0.6
                let boundary = overlaps ? previous!.start+previous!.duration*0.3 : union.end
                let start = min(raw.start,max(0,boundary,raw.start-amount))
                flat[i].line.range.start = start
                if i + 1 < flat.count, flat[i + 1].line.isBackground {
                    flat[i + 1].line.range.start = start
                }
                union = raw.start < union.end ? LyricRange(min(union.start,raw.start),max(union.end,raw.end)) : raw
                previous = raw
            }
            restore(flat, into: &groups)
            return groups
        }

        // Keep authored ranges immutable while resolving starts backwards.
        // End caps are applied only after every start has been resolved; an
        // immediate cap uses the previous line's old start and creates the
        // false overlap documented for the 33.469/33.877 sample.
        let raw = flat.map(\.line)
        var caps: [Int:Double] = [:]
        for i in flat.indices.reversed() {
            guard !flat[i].line.isBackground else { continue }
            var previousIndex = -1
            var previousEnd = 0.0
            var previousRawEnd: Double?
            if i > 0 {
                previousIndex = i - 1
                if flat[previousIndex].line.isBackground { previousIndex -= 1 }
                if previousIndex >= 0 {
                    previousEnd = flat[previousIndex].line.range.end
                    previousRawEnd = raw[previousIndex].range.end
                }
            }
            let rawStart = raw[i].range.start
            let rawGap = previousRawEnd.map { rawStart - $0 }
            let hasOriginalOverlap = rawGap.map { $0 < 0 } ?? false
            let near = rawGap.map { !hasOriginalOverlap && $0 <= timing.nearSwitchGap } ?? false
            let lineLeadIn = near ? timing.leadIn : 1.0
            let leadInStart = max(0,rawStart-lineLeadIn)
            let start = hasOriginalOverlap || near ? leadInStart : max(previousEnd,leadInStart)
            let applied = max(0,rawStart-start)

            if near, !hasOriginalOverlap, previousIndex >= 0 {
                let clipped = min(flat[previousIndex].line.range.end,start)
                caps[previousIndex] = min(caps[previousIndex] ?? .infinity,clipped)
                let previousBackground = previousIndex + 1
                if previousBackground < flat.count, flat[previousBackground].line.isBackground {
                    caps[previousBackground] = min(caps[previousBackground] ?? .infinity, min(flat[previousBackground].line.range.end,start))
                }
            }

            flat[i].line.range.start = start
            let wordLead = near ? min(applied,timing.leadIn,0.26) : min(applied,0.18,timing.leadIn*0.6)
            advanceFirstWords(&flat[i].line, by:wordLead)
            let nextBackground = i + 1
            if nextBackground < flat.count, flat[nextBackground].line.isBackground {
                flat[nextBackground].line.range.start = start
                advanceFirstWords(&flat[nextBackground].line, by:wordLead)
            }
        }
        for (i,cap) in caps {
            guard flat.indices.contains(i) else { continue }
            flat[i].line.range.end = max(flat[i].line.range.start,min(flat[i].line.range.end,cap))
            let end = flat[i].line.range.end
            let background = i + 1
            if background < flat.count, flat[background].line.isBackground {
                flat[background].line.range.end = max(flat[background].line.range.start,min(flat[background].line.range.end,end))
            }
        }
        restore(flat, into: &groups)
        return groups
    }

    private static func advanceFirstWords(_ line: inout LyricLine, by lead: Double) {
        let indexes = line.words.indices.filter { !line.words[$0].text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.prefix(2)
        guard let firstMeaningful = indexes.first, let last = indexes.last else { return }
        // Match the legacy adapter's frontWords selection: a leading space or
        // other finite token may participate in the first-word envelope, but
        // the segment anchor is the first valid word rather than blindly the
        // first array element.
        let frontWords = line.words[0...last].filter {
            $0.range.start.isFinite && $0.range.end.isFinite && $0.range.end >= $0.range.start
        }
        let first = frontWords.first ?? line.words[firstMeaningful]
        // All native lyric times are seconds.  The legacy AMLL patch uses a
        // one-millisecond floor (its values are milliseconds); using `1` here
        // would silently turn that floor into a full second and make the
        // second front word lag behind on short LDDC segments.
        let end = max(first.range.start+0.001,frontWords.map(\.range.end).max() ?? first.range.end)
        let segmentDuration = max(0.001,end-first.range.start)
        let lead = min(lead,max(0,first.range.start-line.range.start))
        guard lead>0 else { return }
        for i in 0...last {
            let range = line.words[i].range
            guard range.start.isFinite, range.end.isFinite, range.end >= range.start else { continue }
            let a = Curves.clamp((range.start-first.range.start)/segmentDuration), b = Curves.clamp((range.end-first.range.start)/segmentDuration)
            let start = max(line.range.start,range.start-lead*(1-a))
            line.words[i].range = LyricRange(start,max(start,range.end-lead*(1-b)))
        }
    }

    /// Keep the app's historical preprocessor behavior independent of the
    /// native timing toggle: whitespace and line bounds are normalized before
    /// the optional early-switch policy runs. A one-span LDDC line remains
    /// line-timed, but its range still follows the authored word span.
    private static func normalizeLineWordsAndBounds(_ line: inout LyricLine) {
        for index in line.words.indices {
            line.words[index].text = line.words[index].text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        guard !line.words.isEmpty else { return }
        if line.words.count == 1,
           abs(line.words[0].range.start) < 0.0001,
           abs(line.words[0].range.end) < 0.0001,
           (abs(line.range.start) > 0.0001 || abs(line.range.end) > 0.0001) {
            line.words[0].range = line.range
            return
        }
        guard let first = line.words.first,
              let last = line.words.last,
              first.range.start.isFinite,
              last.range.end.isFinite
        else { return }
        line.range = LyricRange(first.range.start, max(first.range.start,last.range.end))
    }

    private static func syncMainAndBackgroundTimes(_ lines: inout [FlatLine]) {
        guard lines.count > 1 else { return }
        for index in lines.indices.reversed() {
            guard !lines[index].line.isBackground,
                  index + 1 < lines.count,
                  lines[index + 1].line.isBackground else { continue }
            let main = lines[index].line
            let background = lines[index + 1].line
            let words = (main.words + background.words).filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.range.start.isFinite
                    && $0.range.end.isFinite
            }
            guard !words.isEmpty else { continue }
            let shared = LyricRange(
                min(words.map(\.range.start).min() ?? min(main.range.start,background.range.start), main.range.start, background.range.start),
                max(words.map(\.range.end).max() ?? max(main.range.end,background.range.end), main.range.end, background.range.end)
            )
            lines[index].line.range = shared
            lines[index + 1].line.range = shared
        }
    }

    private static func convertExcessiveBackgroundLines(_ lines: inout [FlatLine]) {
        var consecutive = 0
        for index in lines.indices {
            if lines[index].line.isBackground {
                consecutive += 1
                if consecutive > 1 { lines[index].line.isBackground = false }
            } else {
                consecutive = 0
            }
        }
    }

    private static func cleanUnintentionalLineOverlaps(_ lines: inout [FlatLine]) {
        guard lines.count > 1 else { return }
        for index in lines.indices.dropLast() {
            guard !lines[index].line.isBackground else { continue }
            var nextMain = index + 1
            while nextMain < lines.count, lines[nextMain].line.isBackground { nextMain += 1 }
            guard nextMain < lines.count else { continue }
            let overlap = lines[index].line.range.end - lines[nextMain].line.range.start
            let nextDuration = lines[nextMain].line.range.duration
            let intentional = overlap > 0.1 && overlap > nextDuration * 0.1
            guard overlap > 0, !intentional else { continue }
            let boundary = lines[nextMain].line.range.start
            lines[index].line.range.end = max(lines[index].line.range.start,boundary)
            let attachedBackground = index + 1
            if attachedBackground < lines.count, lines[attachedBackground].line.isBackground {
                lines[attachedBackground].line.range.end = max(lines[attachedBackground].line.range.start,boundary)
            }
        }
    }

    private static func restore(_ lines: [FlatLine], into groups: inout [PreparedGroup]) {
        for item in lines where groups.indices.contains(item.groupIndex) {
            switch item.slot {
            case .main:
                groups[item.groupIndex].main = item.line
            case .background:
                groups[item.groupIndex].background = item.line
            }
        }
    }
}
