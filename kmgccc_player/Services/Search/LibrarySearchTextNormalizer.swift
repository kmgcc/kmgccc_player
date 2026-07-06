//
//  LibrarySearchTextNormalizer.swift
//  myPlayer2
//
//  Shared text normalization for metadata, lyrics, and search queries.
//

import Foundation

nonisolated enum LibrarySearchTextNormalizer {
    private static let foldLocale = Locale(identifier: "en_US_POSIX")

    struct NormalizedTextMap: Sendable {
        let normalized: String
        let compact: String
        let normalizedCharacterOffsets: [Int]
        let compactCharacterOffsets: [Int]
    }

    static func normalize(_ value: String) -> String {
        let folded = value
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: foldLocale
            )
            .lowercased()

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(folded.unicodeScalars.count)
        var previousWasSpace = true

        for scalar in folded.unicodeScalars {
            if isSearchableScalar(scalar) {
                scalars.append(scalar)
                previousWasSpace = false
            } else if !previousWasSpace {
                scalars.append(" ")
                previousWasSpace = true
            }
        }

        let normalized = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }

    static func compact(_ value: String) -> String {
        normalize(value).filter { !$0.isWhitespace }
    }

    static func tokens(_ value: String) -> [String] {
        normalize(value)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func mappedNormalize(_ value: String) -> NormalizedTextMap {
        var normalizedCharacters: [Character] = []
        var normalizedOffsets: [Int] = []
        var previousWasSpace = true

        for (characterOffset, character) in value.enumerated() {
            let folded = String(character)
                .precomposedStringWithCompatibilityMapping
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: foldLocale
                )
                .lowercased()

            for scalar in folded.unicodeScalars {
                if isSearchableScalar(scalar) {
                    normalizedCharacters.append(Character(scalar))
                    normalizedOffsets.append(characterOffset)
                    previousWasSpace = false
                } else if !previousWasSpace {
                    normalizedCharacters.append(" ")
                    normalizedOffsets.append(characterOffset)
                    previousWasSpace = true
                }
            }
        }

        while normalizedCharacters.first == " " {
            normalizedCharacters.removeFirst()
            normalizedOffsets.removeFirst()
        }
        while normalizedCharacters.last == " " {
            normalizedCharacters.removeLast()
            normalizedOffsets.removeLast()
        }

        var compactCharacters: [Character] = []
        var compactOffsets: [Int] = []
        compactCharacters.reserveCapacity(normalizedCharacters.count)
        compactOffsets.reserveCapacity(normalizedOffsets.count)

        for (index, character) in normalizedCharacters.enumerated() where !character.isWhitespace {
            compactCharacters.append(character)
            compactOffsets.append(normalizedOffsets[index])
        }

        return NormalizedTextMap(
            normalized: String(normalizedCharacters),
            compact: String(compactCharacters),
            normalizedCharacterOffsets: normalizedOffsets,
            compactCharacterOffsets: compactOffsets
        )
    }

    static func characterNgrams(
        _ value: String,
        minimum: Int = 2,
        maximum: Int = 3,
        limit: Int? = nil
    ) -> [String] {
        let compactValue = compact(value)
        guard !compactValue.isEmpty else { return [] }

        let characters = Array(compactValue)
        var grams: [String] = []
        var seen = Set<String>()
        let lowerBound = max(1, minimum)
        let upperBound = max(lowerBound, maximum)

        for size in lowerBound...upperBound where characters.count >= size {
            for index in 0...(characters.count - size) {
                if let limit, grams.count >= limit {
                    return grams
                }
                let gram = String(characters[index..<(index + size)])
                if seen.insert(gram).inserted {
                    grams.append(gram)
                }
            }
        }

        return grams
    }

    static func queryNgrams(_ query: String) -> [String] {
        let compactQuery = compact(query)
        let count = compactQuery.count
        guard count > 0 else { return [] }
        if count == 1 {
            return characterNgrams(compactQuery, minimum: 1, maximum: 1)
        }
        if count == 2 {
            return characterNgrams(compactQuery, minimum: 2, maximum: 2)
        }
        return characterNgrams(compactQuery, minimum: 2, maximum: 3)
    }

    static func hasCJKOrHangul(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            isCJKScalar(scalar) || isHangulScalar(scalar) || isKanaScalar(scalar)
        }
    }

    private static func isSearchableScalar(_ scalar: UnicodeScalar) -> Bool {
        if CharacterSet.alphanumerics.contains(scalar) {
            return true
        }
        return isCJKScalar(scalar) || isKanaScalar(scalar) || isHangulScalar(scalar)
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF:
            return true
        default:
            return false
        }
    }

    private static func isKanaScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF:
            return true
        default:
            return false
        }
    }

    private static func isHangulScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}
