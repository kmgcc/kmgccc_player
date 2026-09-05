import Foundation

/// Strict TTML input, with named lyric extensions. Legacy/absolute-time normalization is external.
public struct TTMLDecoder {
    public init() {}
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
        guard root.name == "tt", root.uri == TTMLNamespace.tt else {
            throw LyricsError.invalidTTML("Expected tt in the standard TTML namespace. Normalize legacy files outside the engine.")
        }
        if tree.hasDoctype { throw LyricsError.invalidTTML("External entities are not supported in lyric TTML") }
        return try DocumentBuilder(root).build()
    }
}

private enum TTMLNamespace {
    static let tt = "http://www.w3.org/ns/ttml"
    static let metadata = "http://www.w3.org/ns/ttml#metadata"
    static let styling = "http://www.w3.org/ns/ttml#styling"
    static let parameter = "http://www.w3.org/ns/ttml#parameter"
    static let xml = "http://www.w3.org/XML/1998/namespace"
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
            return pair.count == 2 && pair[1] == name && namespaces[pair[0]] == uri
        }?.value
    }
    func inherited(_ name: String, uri: String) -> String? { attr(name, uri: uri) ?? parent?.inherited(name, uri: uri) }
    var role: String { attr("role", uri: TTMLNamespace.metadata) ?? "" }
    var rubyRole: String { attr("ruby", uri: TTMLNamespace.styling) ?? "" }
    var language: String { inherited("lang", uri: TTMLNamespace.xml) ?? "" }
    var key: String {
        attr("id", uri: TTMLNamespace.xml) ?? attributes.first { $0.key.hasSuffix(":key") }?.value ?? ""
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
    var frameRate = 30.0
    var subFrameRate = 1.0
    var tickRate = 1.0
    var diagnostics: [String] = []
    var nextID = 0
    init(_ root: XMLNode) { self.root = root }

    func time(_ value: String) throws -> Double {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let factors: [(String, Double)] = [("ms", 0.001), ("h",3600), ("m",60), ("s",1), ("f",1/frameRate), ("t",1/tickRate)]
        for (suffix, factor) in factors where s.hasSuffix(suffix) {
            if let n = Double(s.dropLast(suffix.count)), n.isFinite, n >= 0 { return n * factor }
            throw LyricsError.invalidTTML("Invalid time: \(s)")
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
        let origin = implicitStart ?? parent.start
        let begin = try node.attr("begin").map(time) ?? 0
        let start = origin + begin
        var end = try node.attr("end").map { origin + (try time($0)) } ?? parent.end
        if let dur = node.attr("dur") { end = min(end, start + (try time(dur))) }
        guard end >= start || start >= parent.end else { throw LyricsError.invalidTTML("end precedes begin in \(node.name)") }
        node.time = LyricRange(min(start,parent.end), max(min(start,parent.end),min(end,parent.end)))
        let sequential = node.attr("timeContainer") == "seq"
        var cursor = start
        for child in node.children where child.uri == TTMLNamespace.tt {
            try resolveTimes(child, parent: node.time, implicitStart: sequential ? cursor : nil)
            if sequential { cursor = child.time.end }
        }
        if !node.time.end.isFinite {
            let ends = node.children.map(\.time.end)
            if !ends.isEmpty, ends.allSatisfy(\.isFinite) { node.time.end = ends.max()! }
        }
    }

    func build() throws -> LyricsDocument {
        let timeBase = root.attr("timeBase",uri:TTMLNamespace.parameter) ?? "media"
        guard timeBase == "media" else { throw LyricsError.invalidTTML("Unsupported TTML timeBase: \(timeBase)") }
        frameRate = Double(root.attr("frameRate",uri:TTMLNamespace.parameter) ?? "30") ?? 0
        subFrameRate = Double(root.attr("subFrameRate",uri:TTMLNamespace.parameter) ?? "1") ?? 0
        if let mult = root.attr("frameRateMultiplier",uri:TTMLNamespace.parameter) {
            let n = mult.split(separator:" ").compactMap { Double($0) }
            guard n.count == 2, n[1] > 0 else { throw LyricsError.invalidTTML("Invalid frameRateMultiplier") }
            frameRate *= n[0]/n[1]
        }
        tickRate = Double(root.attr("tickRate",uri:TTMLNamespace.parameter) ?? (root.attr("frameRate",uri:TTMLNamespace.parameter) == nil ? "1" : String(frameRate * subFrameRate))) ?? 0
        guard frameRate > 0, subFrameRate > 0, tickRate > 0 else { throw LyricsError.invalidTTML("Invalid TTML clock rates") }
        let all = root.descendants
        if all.contains(where: { ["body","div","p","span","br"].contains($0.name) && $0.uri.isEmpty }) {
            throw LyricsError.invalidTTML("Unnamespaced timed content is legacy TTML; normalize it outside the engine.")
        }
        if all.contains(where: { ["set","animate","image","audio"].contains($0.name) && $0.uri == TTMLNamespace.tt }) {
            diagnostics.append("Embedded media/set/animate are outside the AMLL lyric profile.")
        }
        if all.contains(where: { $0.name == "region" || $0.name == "style" }) {
            diagnostics.append("Subtitle region/style layout is not applied; lyric typography is supplied by the host.")
        }
        guard let body = root.children.first(where: { $0.name == "body" && $0.uri == TTMLNamespace.tt }) else { throw LyricsError.invalidTTML("TTML body missing") }
        try resolveTimes(body, parent: LyricRange(0,.infinity))
        let agents = Dictionary(all.filter { $0.name == "agent" && $0.uri == TTMLNamespace.metadata }.map { ($0.key, $0.attr("type") ?? "person") }, uniquingKeysWith: { _,b in b })
        var lastAgent: String?; var lastSide = false
        var groups: [LyricGroup] = []
        for p in body.descendants where p.name == "p" && p.uri == TTMLNamespace.tt {
            let id = p.key.isEmpty ? "line-\(groups.count)" : p.key
            var main = try line(p, id: id)
            main.agent = p.inherited("agent",uri:TTMLNamespace.metadata) ?? "v1"
            let kind = agents[main.agent] ?? "person"
            if kind == "group" { main.isDuet = false }
            else {
                if lastAgent == nil { lastSide = kind == "other" }
                else if main.agent != lastAgent { lastSide.toggle() }
                main.isDuet = lastSide; lastAgent = main.agent
            }
            var bg: LyricLine?
            let backgrounds = p.descendants.filter { candidate in
                guard candidate.role == "x-bg" else { return false }
                var parent = candidate.parent
                while let ancestor = parent, ancestor !== p {
                    if ["x-bg","x-translation","x-roman"].contains(ancestor.role) { return false }
                    parent = ancestor.parent
                }
                return true
            }
            if let b = backgrounds.first {
                bg = try line(b, id: id+"-bg"); bg?.isBackground = true; bg?.isDuet = main.isDuet
                if var bgl = bg, !bgl.words.isEmpty {
                    bgl.words[0].text = bgl.words[0].text.replacingOccurrences(of: "^[（(]+", with: "", options: .regularExpression)
                    let j = bgl.words.count-1
                    bgl.words[j].text = bgl.words[j].text.replacingOccurrences(of: "[）)]+$", with: "", options: .regularExpression)
                    bg = bgl
                }
            }
            attachSidecars(all, key: p.key, main: &main, background: &bg)
            groups.append(LyricGroup(main:main,background:bg))
            for (index,b) in backgrounds.dropFirst().enumerated() {
                var extra = try line(b,id:id+"-extra-bg-\(index)")
                extra.isDuet = main.isDuet; extra.agent = main.agent
                groups.append(LyricGroup(main:extra))
                diagnostics.append("Additional background voice promoted to an independent group, matching AMLL's converter.")
            }
        }
        let title = all.first { $0.name == "title" && $0.uri == TTMLNamespace.metadata }?.text ?? "TTML Lyrics"
        let maximum = groups.map { max($0.main.range.end,$0.background?.range.end ?? 0) }.max() ?? 0
        return LyricsDocument(groups: groups, title: title, duration: max(maximum,body.time.end.isFinite ? body.time.end : maximum), diagnostics: diagnostics)
    }

    func normalized(_ text: String, in node: XMLNode) -> String {
        if node.preservesSpace { return text }
        // XML formatting indentation between timed spans is not sung whitespace.
        if text.contains("\n"), text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return "" }
        return text.replacingOccurrences(of:"\\s+",with:" ",options:.regularExpression)
    }

    func line(_ node: XMLNode, id: String) throws -> LyricLine {
        var words: [LyricWord] = []; var translations: [LyricTextLayer] = []; var romans: [LyricTextLayer] = []
        var timed = false
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
                        let ruby = child.descendants.filter { $0.rubyRole == "text" }.map { RubySyllable(text:normalized($0.text,in:$0),range:$0.time) }
                        var w = LyricWord(id:"\(id)-\(words.count)",text:base,range:child.time,ruby:ruby)
                        w.obscene = child.attributes.contains { $0.key.hasSuffix(":obscene") && $0.value == "true" }
                        words.append(w); timed = timed || child.attr("begin") != nil || ruby.contains { $0.range != node.time }; continue
                    }
                    if child.uri != TTMLNamespace.tt { continue }
                    let nested = child.children.contains { $0.name == "span" || $0.name == "br" }
                    if nested { visit(child); continue }
                    let t = normalized(child.text,in:child)
                    if !t.isEmpty {
                        var word = LyricWord(id:"\(id)-\(words.count)",text:t,range:child.time)
                        word.obscene = child.attributes.contains { $0.key.hasSuffix(":obscene") && $0.value == "true" }
                        word.emptyBeat = child.attributes.first { $0.key.hasSuffix(":empty-beat") }.flatMap { Int($0.value) }
                        words.append(word)
                        timed = timed || child.attr("begin") != nil || child.attr("end") != nil || child.attr("dur") != nil
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
        return LyricLine(id:id,range:node.time,words:words,translations:translations,romanizations:romans,isWordTimed:timed,language:node.language)
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
