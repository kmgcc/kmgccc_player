import Foundation

nonisolated struct AudioProgramMetadata: Sendable, Equatable {
    let title: String
    let artist: String
    let album: String
    let albumArtist: String?
}

nonisolated enum AudioProgramResolver {
    private struct CueTrack {
        let number: Int
        let file: String
        var title = ""
        var artist = ""
        var start: Int64?
    }

    static func tracks(at url: URL, area: Int = -1, cueDescriptor: URL? = nil) throws -> [AudioProgramTrack]? {
        let ext = url.pathExtension.lowercased()
        if ext == "iso" { return try sacdTracks(at: url, area: area) }
        if ext == "cue" { return try cueTracks(at: url) }
        if let cueDescriptor {
            return try cueTracks(at: cueDescriptor).filter { $0.url.standardizedFileURL == url.standardizedFileURL }
        }
        let sidecars = try externalCues(for: url)
        if sidecars.count > 1 { throw AudioDecodingError.failed("发现多份 CUE，请选择分轨描述") }
        if let sidecar = sidecars.first {
            let tracks = try cueTracks(at: sidecar)
            return tracks.filter { $0.url.standardizedFileURL == url.standardizedFileURL }
        }
        if ext == "flac" { return try embeddedFLACTracks(at: url) }
        return nil
    }

    private static func referencedPaths(in text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("FILE ") else { return nil }
            let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let first = value.firstIndex(of: "\""), let last = value.lastIndex(of: "\""), first < last {
                return String(value[value.index(after: first)..<last])
            }
            return value.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        }
    }

    static func referencedAudioURLs(in cueURL: URL) throws -> [URL] {
        let data = try Data(contentsOf: cueURL)
        guard data.count <= 4 * 1024 * 1024 else { throw AudioDecodingError.failed("CUE 文件过大") }
        let text = try decodeCue(data, relativeTo: cueURL.deletingLastPathComponent())
        var files: [URL] = []
        for path in referencedPaths(in: text) {
            let url = URL(fileURLWithPath: path.replacingOccurrences(of: "\\", with: "/"),
                relativeTo: cueURL.deletingLastPathComponent()).standardizedFileURL
            if !files.contains(url) { files.append(url) }
        }
        guard !files.isEmpty else { throw AudioDecodingError.failed("CUE 缺少音频文件声明") }
        return files
    }

    static func externalCues(for audioURL: URL) throws -> [URL] {
        let parent = audioURL.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension.lowercased() == "cue" }.filter { cue in
            guard let data = try? Data(contentsOf: cue), data.count <= 4 * 1024 * 1024,
                  let text = try? decodeCue(data, relativeTo: cue.deletingLastPathComponent()) else { return false }
            return referencedPaths(in: text).contains { path in
                URL(fileURLWithPath: path.replacingOccurrences(of: "\\", with: "/"), relativeTo: parent)
                    .standardizedFileURL == audioURL.standardizedFileURL
            }
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func decodeCue(_ data: Data, relativeTo parent: URL? = nil) throws -> String {
        if data.starts(with: [0xff, 0xfe]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return text }
        if data.starts(with: [0xfe, 0xff]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return text }
        if let text = String(data: data, encoding: .utf8) { return text.replacingOccurrences(of: "\u{feff}", with: "") }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        let encodings = [gb, big5, .shiftJIS]
        var detected: NSString?
        var lossy: ObjCBool = false
        _ = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: encodings.map { NSNumber(value: $0.rawValue) },
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false
        ], convertedString: &detected, usedLossyConversion: &lossy)
        var candidates = encodings.compactMap { String(data: data, encoding: $0) }
        if let detected, !lossy.boolValue { candidates.insert(detected as String, at: 0) }
        if let parent {
            for text in candidates {
                let paths = referencedPaths(in: text)
                if !paths.isEmpty && paths.allSatisfy({ path in
                    FileManager.default.isReadableFile(atPath: URL(fileURLWithPath: path.replacingOccurrences(of: "\\", with: "/"), relativeTo: parent).standardizedFileURL.path)
                }) { return text }
            }
        }
        if let text = candidates.first { return text }
        throw AudioDecodingError.failed("CUE 文本编码无法识别")
    }

    static func cueTracks(at cueURL: URL) throws -> [AudioProgramTrack] {
        let data = try Data(contentsOf: cueURL, options: .mappedIfSafe)
        guard data.count <= 4 * 1024 * 1024 else { throw AudioDecodingError.failed("CUE 文件过大") }
        let text = try decodeCue(data, relativeTo: cueURL.deletingLastPathComponent())
        return try parseCue(text, descriptorURL: cueURL)
    }

    static func parseCue(_ text: String, descriptorURL: URL, embeddedAudioURL: URL? = nil) throws -> [AudioProgramTrack] {
        var album = "", albumArtist = "", file = ""
        var pending: [CueTrack] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard let command = pieces.first else { continue }
            let value = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespaces) : ""
            switch command.uppercased() {
            case "FILE":
                if let first = value.firstIndex(of: "\""), let last = value.lastIndex(of: "\""), first < last {
                    file = String(value[value.index(after: first)..<last])
                } else { file = value.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "" }
            case "TRACK":
                let parts = value.split(whereSeparator: { $0.isWhitespace })
                guard parts.count == 2, parts[1].uppercased() == "AUDIO", let number = Int(parts[0]), number > 0,
                      !file.isEmpty || embeddedAudioURL != nil else { throw AudioDecodingError.failed("CUE 曲目声明无效") }
                pending.append(CueTrack(number: number, file: file))
            case "TITLE":
                let title = unquote(value)
                if pending.isEmpty { album = title } else { pending[pending.count - 1].title = title }
            case "PERFORMER":
                let artist = unquote(value)
                if pending.isEmpty { albumArtist = artist } else { pending[pending.count - 1].artist = artist }
            case "INDEX":
                let parts = value.split(whereSeparator: { $0.isWhitespace })
                guard !pending.isEmpty, parts.count == 2 else { throw AudioDecodingError.failed("CUE 分轨索引无效") }
                if parts[0] == "01" { pending[pending.count - 1].start = try cueTime(String(parts[1])) }
            default: break
            }
        }
        guard !pending.isEmpty, Set(pending.map(\.number)).count == pending.count else { throw AudioDecodingError.failed("CUE 曲目列表无效") }
        let firstPath = pending[0].file.replacingOccurrences(of: "\\", with: "/")
        let firstAudio = embeddedAudioURL ?? URL(fileURLWithPath: firstPath, relativeTo: descriptorURL.deletingLastPathComponent()).standardizedFileURL
        let groupID = AudioMediaSelection.groupID(for: firstAudio)
        let fingerprint = try? ReferencedFileIdentityProvider().fingerprint(for: descriptorURL)
        var resources: [URL: AudioDecoderResource] = [:]
        var result: [AudioProgramTrack] = []
        for (index, track) in pending.enumerated() {
            let path = track.file.replacingOccurrences(of: "\\", with: "/")
            let audioURL = embeddedAudioURL ?? URL(fileURLWithPath: path, relativeTo: descriptorURL.deletingLastPathComponent()).standardizedFileURL
            guard FileManager.default.isReadableFile(atPath: audioURL.path), let start = track.start else {
                throw AudioDecodingError.failed("CUE 引用的音频或曲目起点缺失")
            }
            let resource: AudioDecoderResource
            if let cached = resources[audioURL] { resource = cached }
            else { resource = try AudioDecoderFactory.open(audioURL); resources[audioURL] = resource }
            let end: Int64
            if index + 1 < pending.count, pending[index + 1].file == track.file {
                guard let next = pending[index + 1].start else { throw AudioDecodingError.invalidRange }
                end = next
            } else { end = Int64((Double(resource.length) / resource.sampleRate * 75).rounded(.down)) }
            let firstFrame = Int64((Double(start) * resource.sampleRate / 75).rounded(.down))
            let lastFrame = index + 1 < pending.count && pending[index + 1].file == track.file
                ? Int64((Double(end) * resource.sampleRate / 75).rounded(.down)) : resource.length
            let selection = AudioMediaSelection(kind: .cue, groupID: groupID, trackNumber: track.number,
                start: firstFrame, length: lastFrame - firstFrame, timeScale: Int64(resource.sampleRate), descriptorPath: descriptorURL.path,
                descriptorFingerprint: fingerprint, albumTitle: album, albumArtist: albumArtist)
            _ = try selection.decodedRange(sampleRate: resource.sampleRate, totalFrames: resource.length)
            result.append(AudioProgramTrack(url: audioURL,
                title: track.title.isEmpty ? "第 \(track.number) 轨" : track.title,
                artist: track.artist.isEmpty ? albumArtist : track.artist,
                album: album, albumArtist: albumArtist.isEmpty ? nil : albumArtist, selection: selection))
        }
        return result
    }

    private static func cueTime(_ value: String) throws -> Int64 {
        let parts = value.split(separator: ":").compactMap { Int64($0) }
        guard parts.count == 3, parts[0] >= 0, parts[0] < Int64.max / 4500,
              (0..<60).contains(parts[1]), (0..<75).contains(parts[2]) else { throw AudioDecodingError.invalidRange }
        return (parts[0] * 60 + parts[1]) * 75 + parts[2]
    }
    private static func unquote(_ value: String) -> String {
        value.hasPrefix("\"") && value.hasSuffix("\"")
            ? String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"") : value
    }

    private static func sacdTracks(at url: URL, area: Int) throws -> [AudioProgramTrack] {
        let resource = try AudioDecoderFactory.openPhysical(url, selection: area < 0 ? nil : AudioMediaSelection(
            kind: .sacd, groupID: AudioMediaSelection.groupID(for: url), trackNumber: 1,
            start: 0, length: 1, timeScale: 75, area: area))
        let info = resource.info
        guard let tracks = info.tracks, !tracks.isEmpty else { throw AudioDecodingError.failed("SACD 曲目目录为空") }
        return tracks.map { track in
            let artist = track.artist.isEmpty ? info.album_artist ?? "" : track.artist
            let selection = AudioMediaSelection(kind: .sacd, groupID: AudioMediaSelection.groupID(for: url),
                trackNumber: track.number, start: track.start, length: track.length, timeScale: 75,
                area: info.area, albumTitle: info.album, albumArtist: info.album_artist)
            return AudioProgramTrack(url: url, title: track.title.isEmpty ? "第 \(track.number) 轨" : track.title,
                artist: artist, album: info.album ?? "", albumArtist: info.album_artist, selection: selection)
        }
    }

    private static func commentCue(in data: Data) throws -> String? {
        var offset = 0
        func length() throws -> Int {
            guard offset + 4 <= data.count else { throw AudioDecodingError.invalidRange }
            let value = data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
            offset += 4
            return Int(value)
        }
        let vendor = try length()
        guard vendor <= data.count - offset else { throw AudioDecodingError.invalidRange }
        offset += vendor
        let count = try length()
        guard count <= (data.count - offset) / 4 else { throw AudioDecodingError.invalidRange }
        for _ in 0..<count {
            let size = try length()
            guard size <= data.count - offset else { throw AudioDecodingError.invalidRange }
            let value = String(data: data[offset..<(offset + size)], encoding: .utf8)
            offset += size
            if let value, value.uppercased().hasPrefix("CUESHEET=") { return String(value.dropFirst(9)) }
        }
        return nil
    }

    private static func embeddedFLACTracks(at url: URL) throws -> [AudioProgramTrack]? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else { return nil }
        var cueData: Data?
        var cueText: String?
        for _ in 0..<256 {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { break }
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard length <= 16 * 1024 * 1024 else { throw AudioDecodingError.failed("FLAC 元数据块过大") }
            let block = try handle.read(upToCount: length) ?? Data()
            guard block.count == length else { throw AudioDecodingError.failed("FLAC 元数据块不完整") }
            if header[0] & 0x7f == 5 { cueData = block }
            if header[0] & 0x7f == 4 { cueText = try commentCue(in: block) }
            if header[0] & 0x80 != 0 { break }
        }
        if let text = cueText {
            return try parseCue(text, descriptorURL: url, embeddedAudioURL: url)
        }
        guard let data = cueData, data.count >= 396 else { return nil }
        let resource = try AudioDecoderFactory.open(url)
        func uint64(_ offset: Int) -> UInt64 { data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) } }
        let count = Int(data[395]); var offset = 396
        var entries: [(Int, Int64)] = []
        for _ in 0..<count {
            guard offset + 36 <= data.count else { throw AudioDecodingError.invalidRange }
            let base = uint64(offset), number = Int(data[offset + 8]), indices = Int(data[offset + 35])
            let next = offset + 36 + indices * 12
            guard next <= data.count, base <= UInt64(Int64.max) else { throw AudioDecodingError.invalidRange }
            if number != 170 && number > 0 {
                for i in 0..<indices {
                    let index = offset + 36 + i * 12
                    if data[index + 8] == 1 {
                        let relative = uint64(index)
                        guard relative <= UInt64(Int64.max) - base else { throw AudioDecodingError.invalidRange }
                        entries.append((number, Int64(base + relative)))
                    }
                }
            }
            offset = next
        }
        guard !entries.isEmpty else { return nil }
        return try entries.enumerated().map { index, entry in
            let end = index + 1 < entries.count ? entries[index + 1].1 : resource.length
            let selection = AudioMediaSelection(kind: .cue, groupID: AudioMediaSelection.groupID(for: url),
                trackNumber: entry.0, start: entry.1, length: end - entry.1,
                timeScale: Int64(resource.sampleRate), descriptorPath: url.path)
            _ = try selection.decodedRange(sampleRate: resource.sampleRate, totalFrames: resource.length)
            return AudioProgramTrack(url: url, title: "第 \(entry.0) 轨", artist: "", album: "", albumArtist: nil, selection: selection)
        }
    }
}
