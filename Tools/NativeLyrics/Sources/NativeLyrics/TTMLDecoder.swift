import Foundation

/// Decodes the AMLL TTML profile directly from the source document.
///
/// AMLL uses media-absolute clocks on every timed element. The generic W3C
/// parent-relative interpretation remains available for callers that truly
/// need it, but it is deliberately opt-in so the player cannot accidentally
/// reinterpret its library lyrics.
public struct TTMLDecoder {
    public let profile: TTMLTimingProfile

    public init(profile: TTMLTimingProfile = .amllAbsolute) {
        self.profile = profile
    }

    public func decode(_ data: Data) throws -> LyricsDocument {
        let tree = XMLTree()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = tree
        guard parser.parse(), let root = tree.root else {
            throw LyricsError.invalidTTML(parser.parserError?.localizedDescription ?? "Invalid XML")
        }
        let acceptsLegacyNamespace = profile == .amllAbsolute
        guard root.name == "tt", root.uri == TTMLNamespace.tt || (acceptsLegacyNamespace && root.uri.isEmpty) else {
            throw LyricsError.invalidTTML("Expected tt in the standard TTML namespace.")
        }
        if tree.hasDoctype { throw LyricsError.invalidTTML("External entities are not supported in lyric TTML") }
        return try DocumentBuilder(root, profile: profile).build()
    }
}

private enum TTMLNamespace {
    static let tt = "http://www.w3.org/ns/ttml"
    static let metadata = "http://www.w3.org/ns/ttml#metadata"
    static let styling = "http://www.w3.org/ns/ttml#styling"
    static let parameter = "http://www.w3.org/ns/ttml#parameter"
    static let xml = "http://www.w3.org/XML/1998/namespace"
    static let itunes = "http://itunes.apple.com/lyric-ttml-extensions"
    static let itunesInternal = "http://music.apple.com/lyric-ttml-internal"
    static let amll = "http://www.example.com/ns/amll"

    static func matches(_ actual: String?, expected: String) -> Bool {
        guard let actual else { return false }
        if actual == expected { return true }
        if expected == itunes {
            return actual == itunesInternal
        }
        return false
    }
}

private final class XMLNode {
    enum Content { case text(String), node(XMLNode) }
    let name: String
    let uri: String
    let attributes: [String: String]
    let namespaces: [String: String]
    var content: [Content] = []
    weak var parent: XMLNode?
    var time = LyricRange(0, .infinity)
    init(_ name: String, _ uri: String, _ attributes: [String: String], _ namespaces: [String: String]) {
        self.name = name; self.uri = uri; self.attributes = attributes; self.namespaces = namespaces
    }
    var children: [XMLNode] { content.compactMap { if case .node(let n) = $0 { return n }; return nil } }
    var descendants: [XMLNode] { children.flatMap { [$0] + $0.descendants } }
    var text: String { content.map { switch $0 { case .text(let t): return t; case .node(let n): return n.text } }.joined() }
    func attr(_ name: String, uri: String? = nil) -> String? {
        if uri == nil { return attributes[name] }
        return attributes.first { key, _ in
            let pair = key.split(separator: ":", maxSplits: 1).map(String.init)
            return pair.count == 2
                && pair[1] == name
                && TTMLNamespace.matches(namespaces[pair[0]], expected: uri!)
        }?.value
    }
    func inherited(_ name: String, uri: String) -> String? { attr(name, uri: uri) ?? parent?.inherited(name, uri: uri) }
    var role: String { attr("role", uri: TTMLNamespace.metadata) ?? "" }
    var rubyRole: String { attr("ruby", uri: TTMLNamespace.styling) ?? "" }
    var language: String { inherited("lang", uri: TTMLNamespace.xml) ?? "" }
    var key: String {
        attr("id", uri: TTMLNamespace.xml)
            ?? attr("key", uri: TTMLNamespace.itunes)
            ?? attr("key")
            ?? attributes.first { $0.key.hasSuffix(":key") }?.value
            ?? ""
    }
    var preservesSpace: Bool { inherited("space", uri: TTMLNamespace.xml) == "preserve" }
}

private final class XMLTree: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    var namespaces = ["xml": TTMLNamespace.xml]
    var hasDoctype = false
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { namespaces[prefix] = namespaceURI }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        var scope = stack.last?.namespaces ?? ["xml": TTMLNamespace.xml]
        scope.merge(namespaces) { _, new in new }
        namespaces = ["xml": TTMLNamespace.xml]
        let node = XMLNode(elementName, namespaceURI ?? "", attributeDict, scope)
        node.parent = stack.last
        if let p = stack.last { p.content.append(.node(node)) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.content.append(.text(string)) }
    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespace: String) { stack.last?.content.append(.text(whitespace)) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.content.append(.text(String(decoding: CDATABlock, as: UTF8.self))) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { hasDoctype = true }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}

private final class DocumentBuilder {
    let root: XMLNode
    let profile: TTMLTimingProfile
    var frameRate = 30.0
    var subFrameRate = 1.0
    var tickRate = 1.0
    var diagnostics: [String] = []
    var nextID = 0
    var nextBlockIndex = 0
    var blockIndices: [ObjectIdentifier: Int] = [:]
    init(_ root: XMLNode, profile: TTMLTimingProfile) {
        self.root = root
        self.profile = profile
    }

    private let timedElementNames: Set<String> = ["body", "div", "p", "span", "br"]

    func isTTML(_ node: XMLNode) -> Bool {
        node.uri == TTMLNamespace.tt
            || (profile == .amllAbsolute && node.uri.isEmpty)
    }

    func isTimedElement(_ node: XMLNode) -> Bool {
        timedElementNames.contains(node.name) && isTTML(node)
    }

    func time(_ value: String) throws -> Double {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let factors: [(String, Double)] = [("ms", 0.001), ("h",3600), ("m",60), ("s",1), ("f",1/frameRate), ("t",1/tickRate)]
        for (suffix, factor) in factors where s.hasSuffix(suffix) {
            if let n = Double(s.dropLast(suffix.count)), n.isFinite, n >= 0 { return n * factor }
            throw LyricsError.invalidTTML("Invalid time: \(s)")
        }
        if profile == .amllAbsolute, let seconds = Double(s), seconds.isFinite, seconds >= 0 {
            return seconds
        }
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        var result: Double
        switch p.count {
        case 2:
            // TTML also permits the compact mm:ss clock form. Apple Music
            // lyric TTML uses it for most library files (for example
            // `04:24.615`), so rejecting it would reject otherwise standard
            // media-time expressions before the lyric model is even built.
            guard let minutes = Double(p[0]), let sec = Double(p[1]),
                  minutes >= 0, sec >= 0, sec < 60 else {
                throw LyricsError.invalidTTML("Invalid standard TTML clock: \(s)")
            }
            result = minutes * 60 + sec
        case 3, 4:
            guard let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]),
                  h >= 0, m >= 0, m < 60, sec >= 0, sec < 60 else {
                throw LyricsError.invalidTTML("Invalid standard TTML clock: \(s)")
            }
            result = h * 3600 + m * 60 + sec
        default:
            throw LyricsError.invalidTTML("Invalid standard TTML clock: \(s)")
        }
        if p.count == 4 {
            let f = p[3].split(separator: ".")
            guard let frames = Double(f[0]), frames >= 0, frames < frameRate else { throw LyricsError.invalidTTML("Invalid frame time: \(s)") }
            result += frames/frameRate
            if f.count > 1 {
                guard let sub = Double(f[1]), sub >= 0, sub < subFrameRate else { throw LyricsError.invalidTTML("Invalid subframe: \(s)") }
                result += sub / subFrameRate / frameRate
            }
        }
        guard result.isFinite else { throw LyricsError.invalidTTML("Nonfinite time") }
        return result
    }

    func resolveTimes(_ node: XMLNode, parent: LyricRange, implicitStart: Double? = nil) throws {
        if profile == .amllAbsolute {
            try resolveAbsoluteTimes(node, parent: parent)
            return
        }

        let origin = implicitStart ?? parent.start
        let begin = try node.attr("begin").map(time) ?? 0
        let start = origin + begin
        var end = try node.attr("end").map { origin + (try time($0)) } ?? parent.end
        if let dur = node.attr("dur") { end = min(end, start + (try time(dur))) }
        guard end >= start || start >= parent.end else { throw LyricsError.invalidTTML("end precedes begin in \(node.name)") }
        node.time = LyricRange(min(start,parent.end), max(min(start,parent.end),min(end,parent.end)))
        let sequential = node.attr("timeContainer") == "seq"
        var cursor = start
        for child in node.children where isTTML(child) {
            try resolveTimes(child, parent: node.time, implicitStart: sequential ? cursor : nil)
            if sequential { cursor = child.time.end }
        }
        if !node.time.end.isFinite {
            let ends = node.children.map(\.time.end)
            if !ends.isEmpty, ends.allSatisfy(\.isFinite) { node.time.end = ends.max()! }
        }
    }

    /// AMLL places every timed element directly on the media timeline. Parent
    /// ranges are retained as structural bounds only; they never become an
    /// origin for descendant clocks.
    private func resolveAbsoluteTimes(_ node: XMLNode, parent: LyricRange) throws {
        let begin = try node.attr("begin").map(time)
        let end = try node.attr("end").map(time)
        let duration = try node.attr("dur").map(time)
        let start = begin ?? (node.name == "body" ? 0 : parent.start)
        var declaredEnd = end ?? parent.end
        if let duration {
            declaredEnd = min(declaredEnd, start + duration)
        }
        guard start.isFinite, start >= 0 else {
            throw LyricsError.invalidTTML("Invalid begin time in \(node.name)")
        }
        if declaredEnd < start {
            // A small number of AMLL exports contain a one-frame-ish inverted
            // word range (for example 03:30.349 → 03:30.331). Keep the
            // authored begin as the stable media position, collapse only this
            // clearly recoverable typo, and leave a diagnostic for callers.
            // Larger inversions remain hard errors so malformed source cannot
            // silently reorder the lyric timeline.
            let inversion = start - declaredEnd
            guard profile == .amllAbsolute, inversion <= 0.05 else {
                throw LyricsError.invalidTTML("end precedes begin in \(node.name)")
            }
            diagnostics.append(
                "Corrected a small inverted AMLL timing range in <\(node.name)> (\(inversion)s)."
            )
            declaredEnd = start
        }

        node.time = LyricRange(start, declaredEnd)
        for child in node.children where isTTML(child) {
            try resolveAbsoluteTimes(child, parent: node.time)
        }

        let timedChildren = node.children.filter(isTTML)
        let childStarts = timedChildren.map(\.time.start).filter(\.isFinite)
        let childEnds = timedChildren.map(\.time.end).filter(\.isFinite)
        if begin == nil, node.name != "body", let first = childStarts.min() {
            node.time.start = first
        }
        if end == nil, duration == nil, let last = childEnds.max() {
            node.time.end = last
        }
        if node.time.end < node.time.start {
            throw LyricsError.invalidTTML("end precedes begin in \(node.name)")
        }

        for child in timedChildren {
            let outside = child.time.start < node.time.start - 0.000_001
                || (node.time.end.isFinite && child.time.end > node.time.end + 0.000_001)
            if outside {
                diagnostics.append(
                    "AMLL timing range does not contain <\(child.name)> in <\(node.name)>"
                )
            }
        }
    }

    func build() throws -> LyricsDocument {
        let timeBase = root.attr("timeBase", uri: TTMLNamespace.parameter) ?? "media"
        guard timeBase == "media" else {
            throw LyricsError.invalidTTML("Unsupported TTML timeBase: \(timeBase)")
        }
        frameRate = Double(root.attr("frameRate", uri: TTMLNamespace.parameter) ?? "30") ?? 0
        subFrameRate = Double(root.attr("subFrameRate", uri: TTMLNamespace.parameter) ?? "1") ?? 0
        if let mult = root.attr("frameRateMultiplier", uri: TTMLNamespace.parameter) {
            let n = mult.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
            guard n.count == 2, n[1] > 0 else {
                throw LyricsError.invalidTTML("Invalid frameRateMultiplier")
            }
            frameRate *= n[0] / n[1]
        }
        let defaultTickRate = root.attr("frameRate", uri: TTMLNamespace.parameter) == nil
            ? "1"
            : String(frameRate * subFrameRate)
        tickRate = Double(root.attr("tickRate", uri: TTMLNamespace.parameter) ?? defaultTickRate) ?? 0
        guard frameRate > 0, subFrameRate > 0, tickRate > 0 else {
            throw LyricsError.invalidTTML("Invalid TTML clock rates")
        }

        let all = root.descendants
        let hasLegacyTimedNodes = all.contains { timedElementNames.contains($0.name) && $0.uri.isEmpty }
        if hasLegacyTimedNodes {
            if profile == .w3cRelative {
                throw LyricsError.invalidTTML("Unnamespaced timed content is not valid for the W3C relative profile.")
            }
            diagnostics.append("Accepted legacy AMLL namespace shadows without rewriting the source XML.")
        }
        if all.contains(where: { ["set", "animate", "image", "audio"].contains($0.name) && $0.uri == TTMLNamespace.tt }) {
            diagnostics.append("Embedded media/set/animate are outside the AMLL lyric profile.")
        }
        if all.contains(where: { $0.name == "region" || $0.name == "style" }) {
            diagnostics.append("Subtitle region/style layout is not applied; lyric typography is supplied by the host.")
        }
        guard let body = root.children.first(where: { $0.name == "body" && isTTML($0) }) else {
            throw LyricsError.invalidTTML("TTML body missing")
        }

        let metadata = collectMetadata(all)
        let timingMode = resolveTimingMode(body)
        try resolveTimes(body, parent: LyricRange(0, .infinity))

        let agents = Dictionary(
            all.filter { $0.name == "agent" && $0.uri == TTMLNamespace.metadata }
                .map { ($0.key, $0.attr("type") ?? "person") },
            uniquingKeysWith: { _, b in b }
        )
        var lastAgent: String?
        var lastSide = false
        var groups: [LyricGroup] = []
        for p in body.descendants where p.name == "p" && isTTML(p) {
            let id = p.key.isEmpty ? "line-\(groups.count)" : p.key
            var main = try line(p, id: id, timingMode: timingMode)
            main.agent = p.inherited("agent", uri: TTMLNamespace.metadata)
                ?? p.attr("agent")
                ?? "v1"
            main.songPart = songPart(for: p)
            main.blockIndex = blockIndex(for: p)

            let kind = agents[main.agent] ?? "person"
            if kind == "group" {
                main.isDuet = false
            } else {
                if lastAgent == nil { lastSide = kind == "other" }
                else if main.agent != lastAgent { lastSide.toggle() }
                main.isDuet = lastSide
                lastAgent = main.agent
            }

            var bg: LyricLine?
            let backgrounds = p.descendants.filter { candidate in
                guard candidate.role == "x-bg" else { return false }
                var parent = candidate.parent
                while let ancestor = parent, ancestor !== p {
                    if ["x-bg", "x-translation", "x-roman"].contains(ancestor.role) { return false }
                    parent = ancestor.parent
                }
                return true
            }
            if let b = backgrounds.first {
                bg = try line(b, id: id + "-bg", timingMode: timingMode)
                bg?.isBackground = true
                bg?.isDuet = main.isDuet
                if var bgl = bg, !bgl.words.isEmpty {
                    bgl.words[0].text = bgl.words[0].text.replacingOccurrences(of: "^[（(]+", with: "", options: .regularExpression)
                    let j = bgl.words.count - 1
                    bgl.words[j].text = bgl.words[j].text.replacingOccurrences(of: "[）)]+$", with: "", options: .regularExpression)
                    bg = bgl
                }
            }
            attachSidecars(all, key: p.key, main: &main, background: &bg)
            groups.append(LyricGroup(main: main, background: bg))
            for (index, b) in backgrounds.dropFirst().enumerated() {
                var extra = try line(b, id: id + "-extra-bg-\(index)", timingMode: timingMode)
                extra.isBackground = true
                extra.isDuet = main.isDuet
                extra.agent = main.agent
                extra.songPart = main.songPart
                extra.blockIndex = main.blockIndex
                groups.append(LyricGroup(main: extra))
                diagnostics.append("Additional background voice promoted to an independent group.")
            }
        }

        let title = metadata["musicName"]?.first
            ?? metadata["title"]?.first
            ?? "TTML Lyrics"
        let maximum = groups.map { max($0.main.range.end, $0.background?.range.end ?? 0) }.max() ?? 0
        let duration = max(maximum, body.time.end.isFinite ? body.time.end : maximum)
        return LyricsDocument(
            groups: groups,
            title: title,
            duration: duration,
            diagnostics: diagnostics,
            timingMode: timingMode,
            metadata: metadata
        )
    }

    private func appendMetadata(_ value: String?, key: String, into metadata: inout [String: [String]]) {
        guard let value else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !metadata[key, default: []].contains(trimmed) {
            metadata[key, default: []].append(trimmed)
        }
    }

    private func collectMetadata(_ all: [XMLNode]) -> [String: [String]] {
        var metadata: [String: [String]] = [:]
        appendMetadata(root.attr("lang", uri: TTMLNamespace.xml), key: "language", into: &metadata)
        if let rawTiming = root.attr("timing", uri: TTMLNamespace.itunes) {
            appendMetadata(rawTiming, key: "timingMode", into: &metadata)
        }

        for node in all {
            if node.name == "meta", TTMLNamespace.matches(node.uri, expected: TTMLNamespace.amll),
               let key = node.attr("key"), let value = node.attr("value") {
                appendMetadata(value, key: key, into: &metadata)
            }
            if node.name == "title", node.uri == TTMLNamespace.metadata {
                appendMetadata(node.text, key: "title", into: &metadata)
            }
            if node.name == "songwriter", node.parent?.name == "songwriters" {
                appendMetadata(node.text, key: "songwriters", into: &metadata)
            }
            if node.name == "agent", node.uri == TTMLNamespace.metadata, !node.key.isEmpty {
                let prefix = "agent.\(node.key)"
                appendMetadata(node.attr("type"), key: "\(prefix).type", into: &metadata)
                appendMetadata(node.text, key: "\(prefix).name", into: &metadata)
            }
        }
        return metadata
    }

    private func resolveTimingMode(_ body: XMLNode) -> TTMLTimingMode {
        if let raw = root.attr("timing", uri: TTMLNamespace.itunes)?.lowercased() {
            if raw == "line" { return .line }
            if raw == "word" { return .word }
        }

        let hasTimedWordSpan = body.descendants.contains { node in
            guard node.name == "span", isTTML(node) else { return false }
            guard node.role != "x-translation", node.role != "x-roman", node.role != "x-bg" else { return false }
            return node.attr("begin") != nil || node.attr("end") != nil || node.attr("dur") != nil
        }
        return hasTimedWordSpan ? .word : .line
    }

    private func songPart(for line: XMLNode) -> String? {
        var ancestor = line.parent
        while let node = ancestor {
            if node.name == "div" {
                let value = node.attr("song-part", uri: TTMLNamespace.itunes)
                    ?? node.attr("songPart", uri: TTMLNamespace.itunes)
                if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            ancestor = node.parent
        }
        return nil
    }

    private func blockIndex(for line: XMLNode) -> Int {
        var ancestor = line.parent
        while let node = ancestor {
            if node.name == "div" {
                let identifier = ObjectIdentifier(node)
                if let existing = blockIndices[identifier] { return existing }
                nextBlockIndex += 1
                blockIndices[identifier] = nextBlockIndex
                return nextBlockIndex
            }
            if node.name == "body" { break }
            ancestor = node.parent
        }
        nextBlockIndex += 1
        return nextBlockIndex
    }

    func normalized(_ text: String, in node: XMLNode) -> String {
        if node.preservesSpace { return text }
        // XML formatting indentation between timed spans is not sung whitespace.
        if text.contains("\n"), text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return "" }
        return text.replacingOccurrences(of:"\\s+",with:" ",options:.regularExpression)
    }

    func line(_ node: XMLNode, id: String, timingMode: TTMLTimingMode) throws -> LyricLine {
        var words: [LyricWord] = []; var translations: [LyricTextLayer] = []; var romans: [LyricTextLayer] = []
        var timed = false
        let wordTiming = timingMode == .word
        func visit(_ current: XMLNode) {
            for item in current.content {
                switch item {
                case .text(let text):
                    let t = normalized(text,in:current)
                    if !t.isEmpty { words.append(LyricWord(id:"\(id)-\(words.count)",text:t,range:current.time)) }
                case .node(let child):
                    if child.role == "x-bg" { continue }
                    if child.role == "x-translation" || child.role == "x-roman" {
                        let layer = LyricTextLayer(language:child.language,text:normalized(child.text,in:child).trimmingCharacters(in:.whitespacesAndNewlines))
                        if child.role == "x-translation" { translations.append(layer) } else { romans.append(layer) }
                        continue
                    }
                    if child.name == "br" { words.append(LyricWord(id:"\(id)-\(words.count)",text:"\n",range:current.time)); continue }
                    if child.rubyRole == "container" {
                        let base = child.descendants.filter { $0.rubyRole == "base" }.map(\.text).joined()
                        let ruby = child.descendants.filter { $0.rubyRole == "text" }.map {
                            RubySyllable(
                                text: normalized($0.text, in: $0),
                                range: wordTiming ? $0.time : node.time
                            )
                        }
                        var w = LyricWord(
                            id: "\(id)-\(words.count)",
                            text: base,
                            range: wordTiming ? child.time : node.time,
                            ruby: ruby
                        )
                        w.obscene = child.attributes.contains { $0.key.hasSuffix(":obscene") && $0.value == "true" }
                        words.append(w)
                        timed = timed || (wordTiming && (child.attr("begin") != nil || ruby.contains { $0.range != node.time }))
                        continue
                    }
                    if !isTTML(child) { continue }
                    let nested = child.children.contains { $0.name == "span" || $0.name == "br" }
                    if nested { visit(child); continue }
                    let t = normalized(child.text,in:child)
                    if !t.isEmpty {
                        var word = LyricWord(
                            id: "\(id)-\(words.count)",
                            text: t,
                            range: wordTiming ? child.time : node.time
                        )
                        word.obscene = child.attributes.contains { $0.key.hasSuffix(":obscene") && $0.value == "true" }
                        word.emptyBeat = child.attributes.first { $0.key.hasSuffix(":empty-beat") }.flatMap { Int($0.value) }
                        words.append(word)
                        timed = timed || (wordTiming && (child.attr("begin") != nil || child.attr("end") != nil || child.attr("dur") != nil))
                    }
                }
            }
        }
        visit(node)
        if !node.preservesSpace {
            while words.first?.text == " " { words.removeFirst() }
            while words.last?.text == " " { words.removeLast() }
            if !words.isEmpty { words[0].text = words[0].text.replacingOccurrences(of:"^ +",with:"",options:.regularExpression); words[words.count-1].text = words[words.count-1].text.replacingOccurrences(of:" +$",with:"",options:.regularExpression) }
        }
        if !timed, !words.isEmpty {
            words = [LyricWord(id:id+"-0",text:words.map(\.text).joined(),range:node.time)]
        }
        guard node.time.end.isFinite || words.isEmpty else { throw LyricsError.invalidTTML("Unbounded lyric \(id): provide end or dur") }
        return LyricLine(
            id: id,
            range: node.time,
            words: words,
            translations: translations,
            romanizations: romans,
            isWordTimed: timed,
            language: node.language
        )
    }

    func attachSidecars(_ all: [XMLNode], key: String, main: inout LyricLine, background: inout LyricLine?) {
        guard !key.isEmpty else { return }
        for entry in all where entry.name == "text" && entry.attr("for") == key {
            guard let container = entry.parent, ["translation","transliteration"].contains(container.name) else { continue }
            func layer(_ n: XMLNode) -> LyricTextLayer {
                let text = n.content.map { item -> String in
                    switch item { case .text(let t): return normalized(t,in:n); case .node(let c): return c.role == "x-bg" ? "" : c.text }
                }.joined().trimmingCharacters(in:.whitespacesAndNewlines)
                // iTunes sidecar syllables use media absolute clock values, outside TTML timed body.
                let words = n.children.filter { $0.role != "x-bg" && $0.attr("begin") != nil }.enumerated().compactMap { i,c -> LyricWord? in
                    guard let b = c.attr("begin"), let e = c.attr("end"), let start = try? time(b), let end = try? time(e) else { return nil }
                    return LyricWord(id:key+"-side-\(i)",text:normalized(c.text,in:c),range:LyricRange(start,end))
                }
                return LyricTextLayer(language:entry.language,text:text,words:words)
            }
            if container.name == "translation" { main.translations.append(layer(entry)) }
            else { main.romanizations.append(layer(entry)) }
            if let bg = entry.children.first(where: { $0.role == "x-bg" }), background != nil {
                if container.name == "translation" { background?.translations.append(layer(bg)) } else { background?.romanizations.append(layer(bg)) }
            }
        }
    }
}
