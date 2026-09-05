import Foundation

struct PreparedGroup {
    var source: LyricGroup
    var main: LyricLine
    var background: LyricLine?
    var range: LyricRange { main.range }
    var backgroundFirst: Bool { (background?.words.first?.range.start ?? .infinity) < (main.words.first?.range.start ?? main.range.start) }
}

enum TimingPolicy {
    static func prepare(_ document: LyricsDocument, _ config: LyricsConfiguration) -> [PreparedGroup] {
        let timing = config.timing
        var groups = document.groups.map { source -> PreparedGroup in
            var main = source.main, bg = source.background
            let offset = min(15,max(-15,timing.trackOffset-timing.globalAdvance))
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
            if timing.enabled {
                func reset(_ line: inout LyricLine) {
                    let meaningful = line.words.filter { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
                    if let first = meaningful.first, let last = meaningful.last { line.range = LyricRange(first.range.start,last.range.end) }
                }
                reset(&main); if bg != nil { reset(&bg!) }
                if let b = bg {
                    let shared = LyricRange(min(main.range.start,b.range.start),max(main.range.end,b.range.end))
                    main.range = shared; bg?.range = shared
                }
            }
            return PreparedGroup(source:source,main:main,background:bg)
        }
        // Stable order is important for equal-start duet groups and seek reconstruction.
        groups = groups.enumerated().sorted { a,b in a.element.range.start == b.element.range.start ? a.offset < b.offset : a.element.range.start < b.element.range.start }.map(\.element)
        guard timing.enabled, !groups.isEmpty else { return groups }
        for i in groups.indices.dropLast() {
            let next = groups[i+1].range
            let overlap = groups[i].range.end-next.start
            if overlap > 0 && !(overlap > 0.1 && overlap > next.duration*0.1) {
                groups[i].main.range.end = next.start; groups[i].background?.range.end = next.start
            }
        }
        if config.profile == .upstream {
            // Upstream advance: bounded by the union of the preceding overlap group.
            var previous: LyricRange?; var union = LyricRange(0,0)
            for i in groups.indices {
                let raw = groups[i].range
                let overlaps = previous.map { raw.start < $0.end } ?? false
                let amount = overlaps ? 0.4 : 0.6
                let boundary = overlaps ? previous!.start+previous!.duration*0.3 : union.end
                groups[i].main.range.start = min(raw.start,max(0,boundary,raw.start-amount))
                let start = groups[i].range.start
                groups[i].background?.range.start = start
                union = raw.start < union.end ? LyricRange(min(union.start,raw.start),max(union.end,raw.end)) : raw
                previous = raw
            }
            return groups
        }
        let raw = groups.map(\.range)
        var caps: [Int:Double] = [:]
        for i in groups.indices.reversed() {
            let gap = i > 0 ? raw[i].start-raw[i-1].end : Double.infinity
            let overlap = gap < 0
            let near = !overlap && gap <= timing.nearSwitchGap
            let candidate = max(0,raw[i].start-(near ? timing.leadIn : 1))
            let start = overlap || near ? candidate : max(i>0 ? raw[i-1].end : 0,candidate)
            let applied = max(0,raw[i].start-start)
            groups[i].main.range.start = start
            groups[i].background?.range.start = start
            let wordLead = near ? min(applied,timing.leadIn,0.26) : min(applied,0.18,timing.leadIn*0.6)
            advanceFirstWords(&groups[i].main, by:wordLead)
            if groups[i].background != nil { advanceFirstWords(&groups[i].background!,by:wordLead) }
            if near && i>0 { caps[i-1] = min(caps[i-1] ?? .infinity,start) }
        }
        for (i,cap) in caps {
            groups[i].main.range.end = max(groups[i].range.start,min(groups[i].range.end,cap))
            let end = groups[i].range.end
            groups[i].background?.range.end = end
        }
        return groups
    }

    private static func advanceFirstWords(_ line: inout LyricLine, by lead: Double) {
        let indexes = line.words.indices.filter { !line.words[$0].text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.prefix(2)
        guard let last = indexes.last, let first = line.words.first else { return }
        let end = max(first.range.start+0.001,line.words[0...last].map(\.range.end).max() ?? first.range.end)
        let lead = min(lead,max(0,first.range.start-line.range.start))
        guard lead>0 else { return }
        for i in 0...last {
            let range = line.words[i].range
            let a = Curves.clamp((range.start-first.range.start)/(end-first.range.start)), b = Curves.clamp((range.end-first.range.start)/(end-first.range.start))
            let start = max(line.range.start,range.start-lead*(1-a))
            line.words[i].range = LyricRange(start,max(start,range.end-lead*(1-b)))
        }
    }
}
