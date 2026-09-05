import Foundation
import NativeLyrics

/// The native renderer deliberately accepts only standard, parent-relative
/// TTML.  The player library predates that boundary: its AMLL integration
/// stores Apple lyric TTML with compact `mm:ss` clocks and absolute clock
/// values repeated on every descendant.  This adapter is therefore owned by
/// the Demo import surface, rather than by `TTMLDecoder` or `LyricsView`.
struct DemoTTMLImportResult: Sendable {
    let data: Data
    let document: LyricsDocument
    let repairedNamespace: Bool
    let normalizedAbsoluteTiming: Bool
}

enum DemoTTMLImporter {
    private static let ttNamespace = "http://www.w3.org/ns/ttml"
    private static let timedNames: Set<String> = ["body", "div", "p", "span", "br"]

    static func load(_ data: Data) throws -> DemoTTMLImportResult {
        let decoder = TTMLDecoder()
        let document: XMLDocument
        do {
            // Preserve whitespace-only text nodes between timed spans.  They
            // are sung separators in Apple lyric TTML; XMLDocument's default
            // parser treats them as formatting and drops them on serialize.
            document = try XMLDocument(data: data, options: [.nodePreserveAll])
        } catch {
            if let strictDocument = try? decoder.decode(data) {
                return DemoTTMLImportResult(
                    data: data,
                    document: strictDocument,
                    repairedNamespace: false,
                    normalizedAbsoluteTiming: false
                )
            }
            throw LyricsError.invalidTTML("Invalid XML: \(error.localizedDescription)")
        }

        guard let root = document.rootElement(), root.localName == "tt" else {
            if let strictDocument = try? decoder.decode(data) { return result(data: data, document: strictDocument) }
            throw LyricsError.invalidTTML("Expected a TTML document with a <tt> root element.")
        }

        let body = descendants(of: root).first { $0.localName == "body" }
        let absolute = body.map(looksLikeAbsoluteTiming) ?? false
        let namespaceRepair = needsNamespaceRepair(root)

        // A strict document that already uses the standard parent-relative
        // model can go straight through without a serialize/parse round trip.
        // Decode only after this inexpensive structural inspection so a
        // library scan does not parse every file twice.
        if !namespaceRepair, !absolute, let strictDocument = try? decoder.decode(data) {
            return result(data: data, document: strictDocument)
        }

        if namespaceRepair { repairStructuralNamespaces(root) }
        if absolute, let body {
            try normalizeAbsoluteTimes(body, origin: 0)
        }

        let normalizedData = document.xmlData(options: [.nodeCompactEmptyElement])
        do {
            let normalizedDocument = try decoder.decode(normalizedData)
            return DemoTTMLImportResult(
                data: normalizedData,
                document: normalizedDocument,
                repairedNamespace: namespaceRepair,
                normalizedAbsoluteTiming: absolute
            )
        } catch {
            if !namespaceRepair, !absolute, let strictDocument = try? decoder.decode(data) {
                return result(data: data, document: strictDocument)
            }
            let detail = error.localizedDescription
            throw LyricsError.invalidTTML(
                "The file is not compatible with the Demo TTML import boundary. \(detail)"
            )
        }
    }

    static func metadataTitle(_ data: Data) -> String? {
        guard let document = try? XMLDocument(data: data, options: [.nodePreserveAll]) else { return nil }
        guard let root = document.rootElement() else { return nil }
        for element in descendants(of: root) where element.localName == "meta" {
            guard attribute("key", from: element) == "musicName",
                  let value = attribute("value", from: element),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return value
        }
        return nil
    }

    private static func result(data: Data, document: LyricsDocument) -> DemoTTMLImportResult {
        DemoTTMLImportResult(
            data: data,
            document: document,
            repairedNamespace: false,
            normalizedAbsoluteTiming: false
        )
    }

    private static func descendants(of element: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            result.append(child)
            result.append(contentsOf: descendants(of: child))
        }
        return result
    }

    private static func children(of element: XMLElement) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func timed(_ element: XMLElement) -> Bool {
        timedNames.contains(element.localName ?? element.name ?? "")
    }

    private static func attribute(_ name: String, from element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    private static func looksLikeAbsoluteTiming(_ body: XMLElement) -> Bool {
        var equalFirstChildren = 0
        var comparisons = 0
        var zeroFirstChildren = 0

        func visit(_ parent: XMLElement) {
            let parentBegin = attribute("begin", from: parent).flatMap(parseTime)
            let timedChildren = children(of: parent).filter { timed($0) && attribute("begin", from: $0) != nil }
            if let parentBegin, parentBegin > 0.25,
               let childBegin = timedChildren.first.flatMap({ attribute("begin", from: $0).flatMap(parseTime) }) {
                comparisons += 1
                if abs(childBegin - parentBegin) < 0.02 { equalFirstChildren += 1 }
                if childBegin < 0.02 { zeroFirstChildren += 1 }
            }
            for child in children(of: parent) {
                visit(child)
            }
        }

        visit(body)
        guard comparisons >= 2 else { return false }
        // AMLL's legacy export repeats the absolute start on the div, p and
        // first span. Parent-relative TTML normally starts child spans at 0.
        // A one-line instrumental still has the same div → p → span chain,
        // so two repeated edges are enough to classify it.
        return (equalFirstChildren >= 2 && equalFirstChildren * 2 >= comparisons && equalFirstChildren > zeroFirstChildren)
    }

    private static func needsNamespaceRepair(_ root: XMLElement) -> Bool {
        guard root.uri != ttNamespace else {
            return descendants(of: root).contains { timedNames.contains($0.localName ?? $0.name ?? "") && $0.uri != ttNamespace }
        }
        return true
    }

    private static func repairStructuralNamespaces(_ root: XMLElement) {
        // XMLDocument serializes a default namespace onto all unprefixed
        // descendants. Removing explicit empty declarations on descendants is
        // required for the library's older export, which wrote `xmlns=""` on
        // every timed node and thereby shadowed the root namespace.
        if root.uri != ttNamespace {
            if let prefix = root.prefix, !prefix.isEmpty { root.removeNamespace(forPrefix: prefix) }
            root.name = root.localName ?? root.name ?? "tt"
        }
        root.removeNamespace(forPrefix: "")
        root.addNamespace(XMLNode.namespace(withName: "", stringValue: ttNamespace) as! XMLNode)
        for element in descendants(of: root) where timedNames.contains(element.localName ?? element.name ?? "") {
            if element.uri != ttNamespace {
                if let prefix = element.prefix, !prefix.isEmpty { element.removeNamespace(forPrefix: prefix) }
                element.removeNamespace(forPrefix: "")
                element.name = element.localName ?? element.name
            }
        }
    }

    private static func normalizeAbsoluteTimes(_ element: XMLElement, origin: Double) throws {
        let absoluteStart = attribute("begin", from: element).flatMap(parseTime) ?? origin
        if attribute("begin", from: element) != nil {
            setTime(max(0, absoluteStart - origin), attribute: "begin", on: element)
        }
        if let end = attribute("end", from: element), let absoluteEnd = parseTime(end) {
            setTime(max(0, absoluteEnd - origin), attribute: "end", on: element)
        } else if attribute("end", from: element) != nil {
            throw LyricsError.invalidTTML("Invalid absolute end time: \(attribute("end", from: element) ?? "")")
        }
        if let dur = attribute("dur", from: element), let duration = parseTime(dur) {
            setTime(max(0, duration), attribute: "dur", on: element)
        } else if attribute("dur", from: element) != nil {
            throw LyricsError.invalidTTML("Invalid duration: \(attribute("dur", from: element) ?? "")")
        }

        for child in children(of: element) where timed(child) {
            try normalizeAbsoluteTimes(child, origin: absoluteStart)
        }
    }

    private static func setTime(_ value: Double, attribute: String, on element: XMLElement) {
        let text = String(format: "%.6fs", value)
        if let existing = element.attribute(forName: attribute) {
            existing.stringValue = text
        } else {
            element.addAttribute(XMLNode.attribute(withName: attribute, stringValue: text) as! XMLNode)
        }
    }

    private static func parseTime(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes: [(String, Double)] = [("ms", 0.001), ("h", 3600), ("m", 60), ("s", 1)]
        for (suffix, factor) in suffixes where value.hasSuffix(suffix) {
            guard let number = Double(value.dropLast(suffix.count)), number.isFinite, number >= 0 else { return nil }
            return number * factor
        }
        // The player fork also has older Apple exports whose timed
        // attributes are bare decimal seconds (for example `15.357`).  They
        // are accepted at this Demo adapter boundary and serialized back as
        // explicit seconds before the strict native decoder sees them.
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 2:
            guard let minutes = Double(parts[0]), let seconds = Double(parts[1]),
                  minutes >= 0, seconds >= 0, seconds < 60 else { return nil }
            return minutes * 60 + seconds
        case 3:
            guard let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]),
                  hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        default:
            return nil
        }
    }
}

struct DemoLibrarySong: Sendable, Equatable {
    let title: String
    let subtitle: String
    let lyricURL: URL
    let audioURL: URL?
    let rootLabel: String
}

enum DemoLibraryCatalog {
    private static let maxSongs = 48

    static func discover() -> [DemoLibrarySong] {
        let registered = registeredRoots()
        let roots = registered.isEmpty
            ? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")]
            : registered
        var lyricURLs = Set<URL>()
        for root in roots {
            let tracks = root.appendingPathComponent("Tracks", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: tracks,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let lyric = entry.appendingPathComponent("lyrics.ttml")
                guard FileManager.default.fileExists(atPath: lyric.path) else { continue }
                lyricURLs.insert(lyric.standardizedFileURL)
            }
        }

        // A registry can be stale during a first launch.  Only then fall back
        // to a bounded directory walk, instead of traversing every audio and
        // artwork file under ~/Music on every Demo launch.
        if lyricURLs.isEmpty, !registered.isEmpty {
            let music = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
            if let enumerator = FileManager.default.enumerator(
                at: music,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator {
                    guard url.lastPathComponent == "Tracks" else { continue }
                    for entry in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                        let lyric = entry.appendingPathComponent("lyrics.ttml")
                        if FileManager.default.fileExists(atPath: lyric.path) { lyricURLs.insert(lyric.standardizedFileURL) }
                    }
                }
            }
        }

        let songs = lyricURLs.compactMap(makeSong)
        return songs.sorted {
            let left = $0.title.localizedStandardCompare($1.title)
            if left == .orderedSame { return $0.lyricURL.path < $1.lyricURL.path }
            return left == .orderedAscending
        }.prefix(maxSongs).map { $0 }
    }

    private static func registeredRoots() -> [URL] {
        let registryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kmgccc.player/LibraryRegistry.json")
        guard let data = try? Data(contentsOf: registryURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let libraries = object["libraries"] as? [[String: Any]] else { return [] }
        return libraries.compactMap { item in
            guard let path = item["lastKnownPath"] as? String, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
    }

    private static func makeSong(url: URL) -> DemoLibrarySong? {
        guard let data = try? Data(contentsOf: url), (try? DemoTTMLImporter.load(data)) != nil else { return nil }
        let meta = readMetadata(at: url.deletingLastPathComponent().appendingPathComponent("meta.json"))
        let title = meta.title ?? DemoTTMLImporter.metadataTitle(data) ?? url.deletingLastPathComponent().lastPathComponent
        let subtitle = [meta.artist, meta.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let directory = url.deletingLastPathComponent()
        let audio = ["audio.m4a", "audio.mp3", "audio.flac", "audio.wav"].map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let rootLabel = rootName(for: url)
        return DemoLibrarySong(title: title, subtitle: subtitle, lyricURL: url, audioURL: audio, rootLabel: rootLabel)
    }

    private struct Meta {
        var title: String?
        var artist: String?
        var album: String?
    }

    private static func readMetadata(at url: URL) -> Meta {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Meta() }
        func string(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        return Meta(title: string("title"), artist: string("artist"), album: string("album"))
    }

    private static func descendants(of element: XMLElement?) -> [XMLElement] {
        guard let element else { return [] }
        var result: [XMLElement] = []
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            result.append(child)
            result.append(contentsOf: descendants(of: child))
        }
        return result
    }

    private static func rootName(for url: URL) -> String {
        let components = url.pathComponents
        if let index = components.lastIndex(where: { $0.hasSuffix("kmgccc_player Library") }), index > 0 {
            return components[index].replacingOccurrences(of: "kmgccc_player Library", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Library"
                : components[index]
        }
        return "Music"
    }
}
