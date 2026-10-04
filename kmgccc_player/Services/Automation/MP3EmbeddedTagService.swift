import Darwin
import Foundation

/// Lossless ID3v2 editing for MPEG audio. Unsupported ID3 features and other
/// containers are rejected before the source file is replaced.
nonisolated enum MP3EmbeddedTagService {
    nonisolated struct WriteRequest: Sendable {
        let trackID: UUID
        let fileURL: URL
        let fileName: String
        let expectedTrackRevision: String
        let fields: [String: String?]
    }

    nonisolated enum TagError: Error, LocalizedError, Equatable {
        case unsupportedContainer
        case unsupportedID3Version
        case unsupportedID3Flags
        case malformedTag
        case oversizedTag
        case noFields
        case unsafeFile
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedContainer: "Only MP3 audio with ID3v2 tags is currently supported."
            case .unsupportedID3Version: "Only ID3v2.3 and ID3v2.4 tags are supported."
            case .unsupportedID3Flags: "This ID3 tag uses flags that cannot be preserved safely."
            case .malformedTag: "The ID3 tag is malformed."
            case .oversizedTag: "The ID3 tag exceeds the supported 64 MiB limit."
            case .noFields: "At least one supported tag field is required."
            case .unsafeFile: "The audio file cannot be safely replaced."
            case .verificationFailed: "The staged ID3 update did not pass readback verification."
            }
        }
    }

    nonisolated struct TagValues: Codable, Equatable, Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var composer: String?
        var genre: String?
        var year: String?
        var trackNumber: String?
        var discNumber: String?
        var comment: String?
        var lyrics: String?

        subscript(field: String) -> String? {
            get {
                switch field {
                case "title": title
                case "artist": artist
                case "album": album
                case "albumArtist": albumArtist
                case "composer": composer
                case "genre": genre
                case "year": year
                case "trackNumber": trackNumber
                case "discNumber": discNumber
                case "comment": comment
                case "lyrics": lyrics
                default: nil
                }
            }
            set {
                switch field {
                case "title": title = newValue
                case "artist": artist = newValue
                case "album": album = newValue
                case "albumArtist": albumArtist = newValue
                case "composer": composer = newValue
                case "genre": genre = newValue
                case "year": year = newValue
                case "trackNumber": trackNumber = newValue
                case "discNumber": discNumber = newValue
                case "comment": comment = newValue
                case "lyrics": lyrics = newValue
                default: break
                }
            }
        }
    }

    private nonisolated struct ParsedTag {
        let version: UInt8
        let body: Data
        let audioOffset: UInt64
    }

    private nonisolated struct Frame {
        let id: String
        let bytes: Data
        let payload: Data
        let flags: (UInt8, UInt8)
    }

    private nonisolated static let maximumTagBytes = 64 * 1_048_576
    private nonisolated static let frameIDs: [String: String] = [
        "title": "TIT2",
        "artist": "TPE1",
        "album": "TALB",
        "albumArtist": "TPE2",
        "composer": "TCOM",
        "genre": "TCON",
        "year": "TDRC",
        "trackNumber": "TRCK",
        "discNumber": "TPOS",
        "comment": "COMM",
        "lyrics": "USLT"
    ]

    nonisolated static let supportedFields = Set(frameIDs.keys)

    nonisolated static func publicMessage(for error: Error) -> String {
        if let tagError = error as? TagError {
            return tagError.localizedDescription
        }
        if error is CancellationError {
            return "The update was cancelled before the source file was replaced."
        }
        return "The MP3 file could not be read or updated safely."
    }

    nonisolated static func read(from url: URL) throws -> TagValues {
        let parsed = try parseFile(at: url)
        return try decodeValues(from: parsed.body, version: parsed.version)
    }

    /// Atomically replaces an MP3 after writing and verifying a same-directory
    /// staging file. A failure before rename leaves the original untouched.
    nonisolated static func patch(
        at url: URL,
        fields: [String: String?]
    ) throws -> TagValues {
        guard !fields.isEmpty else { throw TagError.noFields }
        guard fields.keys.allSatisfy(supportedFields.contains) else { throw TagError.noFields }
        let sourceValues = try parseFile(at: url)
        let frames = try parseFrames(sourceValues.body, version: sourceValues.version)
        let replacedIDs = Set(fields.keys.compactMap { frameIDs[$0] })
        let preservedFrames = frames.filter { !replacedIDs.contains($0.id) }.map(\.bytes)
        let version = sourceValues.version
        var newFrames = preservedFrames
        for field in fields.keys.sorted() {
            guard let frameID = frameIDs[field],
            let value = fields[field] ?? nil else { continue }
            newFrames.append(try makeFrame(id: frameID, value: value, version: version))
        }
        let body = newFrames.reduce(into: Data()) { $0.append($1) }
        guard body.count <= maximumTagBytes else { throw TagError.oversizedTag }
        let tagHeader = makeHeader(version: version, bodySize: body.count)
        let parent = url.deletingLastPathComponent()
        let stagingURL = parent.appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).\(UUID().uuidString).tagtmp.mp3")
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard sourceAttributes[.type] as? FileAttributeType == .typeRegular,
              !(try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) else {
            throw TagError.unsafeFile
        }

        do {
            try writeStagedFile(
                source: url,
                staging: stagingURL,
                sourceOffset: sourceValues.audioOffset,
                header: tagHeader,
                body: body,
                permissions: sourceAttributes[.posixPermissions] as? NSNumber
            )
            try Task.checkCancellation()
            let stagedValues = try read(from: stagingURL)
            for (field, value) in fields where stagedValues[field] != (value ?? nil) {
                throw TagError.verificationFailed
            }
            guard rename(stagingURL.path, url.path) == 0 else { throw TagError.unsafeFile }
            return stagedValues
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    private nonisolated static func parseFile(at url: URL) throws -> ParsedTag {
        guard url.pathExtension.lowercased() == "mp3",
              !(try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) else {
            throw TagError.unsupportedContainer
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 10) ?? Data()
        if header.count >= 10, header.prefix(3) == Data("ID3".utf8) {
            let version = header[3]
            guard version == 3 || version == 4 else { throw TagError.unsupportedID3Version }
            guard header[5] == 0 else { throw TagError.unsupportedID3Flags }
            let bodySize = try decodeSynchsafe(header[6..<10])
            guard bodySize <= maximumTagBytes else { throw TagError.oversizedTag }
            guard let body = try handle.read(upToCount: bodySize), body.count == bodySize else {
                throw TagError.malformedTag
            }
            let offset = UInt64(10 + bodySize)
            try validateMPEGFrame(at: offset, in: handle)
            return ParsedTag(version: version, body: body, audioOffset: offset)
        }
        try validateMPEGFrame(at: 0, in: handle)
        return ParsedTag(version: 4, body: Data(), audioOffset: 0)
    }

    private nonisolated static func validateMPEGFrame(at offset: UInt64, in handle: FileHandle) throws {
        try handle.seek(toOffset: offset)
        guard let bytes = try handle.read(upToCount: 2), bytes.count == 2,
              bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 else {
            throw TagError.unsupportedContainer
        }
    }

    private nonisolated static func parseFrames(_ body: Data, version: UInt8) throws -> [Frame] {
        var result: [Frame] = []
        var offset = 0
        while offset < body.count {
            if body[offset] == 0 { break }
            guard offset + 10 <= body.count else { throw TagError.malformedTag }
            let header = body.subdata(in: offset..<(offset + 10))
            guard let id = String(data: header.prefix(4), encoding: .ascii),
                  id.utf8.count == 4,
                  id.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
                throw TagError.malformedTag
            }
            let payloadSize: Int
            if version == 4 {
                payloadSize = try decodeSynchsafe(header[4..<8])
            } else {
                payloadSize = Int(header[4]) << 24
                    | Int(header[5]) << 16
                    | Int(header[6]) << 8
                    | Int(header[7])
            }
            guard payloadSize >= 0, payloadSize <= body.count - offset - 10 else {
                throw TagError.malformedTag
            }
            let end = offset + 10 + payloadSize
            result.append(
                Frame(
                    id: id,
                    bytes: body.subdata(in: offset..<end),
                    payload: body.subdata(in: (offset + 10)..<end),
                    flags: (header[8], header[9])
                )
            )
            offset = end
        }
        return result
    }

    private nonisolated static func decodeValues(from body: Data, version: UInt8) throws -> TagValues {
        let frames = try parseFrames(body, version: version)
        var values = TagValues()
        for frame in frames where frame.flags.0 == 0 && frame.flags.1 == 0 {
            let field = frameIDs.first(where: { $0.value == frame.id })?.key
            guard let field, let value = decodeFrame(frame, version: version) else { continue }
            values[field] = value
        }
        return values
    }

    private nonisolated static func decodeFrame(_ frame: Frame, version: UInt8) -> String? {
        if frame.id == "COMM" || frame.id == "USLT" {
            guard frame.payload.count >= 4 else { return nil }
            let encoding = frame.payload[0]
            let text = frame.payload.dropFirst(4)
            let delimiter = encoding == 1 || encoding == 2 ? Data([0, 0]) : Data([0])
            guard let index = text.range(of: delimiter) else { return nil }
            return decodeText(Data(text[index.upperBound...]), encoding: encoding)
        }
        guard let first = frame.payload.first else { return nil }
        return decodeText(Data(frame.payload.dropFirst()), encoding: first)
    }

    private nonisolated static func decodeText(_ data: Data, encoding: UInt8) -> String? {
        let trimmed = Data(data.prefix { $0 != 0 })
        switch encoding {
        case 0: return String(data: trimmed, encoding: .isoLatin1)
        case 1: return String(data: data, encoding: .utf16)
        case 2: return String(data: trimmed, encoding: .utf16BigEndian)
        case 3: return String(data: trimmed, encoding: .utf8)
        default: return nil
        }
    }

    private nonisolated static func makeFrame(id: String, value: String, version: UInt8) throws -> Data {
        let payload: Data
        if id == "COMM" || id == "USLT" {
            var content = Data([version == 3 ? 1 : 3])
            content.append(contentsOf: [0x65, 0x6E, 0x67])
            content.append(version == 3 ? Data([0, 0]) : Data([0]))
            content.append(try encodedTextBody(value, version: version))
            payload = content
        } else {
            payload = try encodedText(value, version: version)
        }
        let frameSize = payload.count
        var result = Data(id.utf8)
        result.append(version == 4 ? encodeSynchsafe(frameSize) : encodeUInt32(frameSize))
        result.append(contentsOf: [0, 0])
        result.append(payload)
        return result
    }

    private nonisolated static func encodedText(_ text: String, version: UInt8) throws -> Data {
        var data = Data([version == 4 ? 3 : 1])
        data.append(try encodedTextBody(text, version: version))
        return data
    }

    private nonisolated static func encodedTextBody(_ text: String, version: UInt8) throws -> Data {
        if version == 4 {
            guard let value = text.data(using: .utf8) else { throw TagError.malformedTag }
            return value
        }
        guard let value = text.data(using: .utf16) else { throw TagError.malformedTag }
        return value
    }

    private nonisolated static func makeHeader(version: UInt8, bodySize: Int) -> Data {
        var header = Data("ID3".utf8)
        header.append(contentsOf: [version, 0, 0])
        header.append(encodeSynchsafe(bodySize))
        return header
    }

    private nonisolated static func decodeSynchsafe(_ bytes: Data.SubSequence) throws -> Int {
        guard bytes.count == 4, bytes.allSatisfy({ $0 & 0x80 == 0 }) else {
            throw TagError.malformedTag
        }
        return bytes.reduce(0) { ($0 << 7) | Int($1) }
    }

    private nonisolated static func encodeSynchsafe(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }

    private nonisolated static func encodeUInt32(_ value: Int) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private nonisolated static func writeStagedFile(
        source: URL,
        staging: URL,
        sourceOffset: UInt64,
        header: Data,
        body: Data,
        permissions: NSNumber?
    ) throws {
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
            throw TagError.unsafeFile
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: staging)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.write(contentsOf: header)
        try output.write(contentsOf: body)
        try input.seek(toOffset: sourceOffset)
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        try output.close()
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: staging.path)
        }
    }
}
