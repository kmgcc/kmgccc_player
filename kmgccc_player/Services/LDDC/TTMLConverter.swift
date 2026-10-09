//
//  TTMLConverter.swift
//  myPlayer2
//
//  kmgccc_player - Raw Lyrics to TTML Converter
//  Uses native Swift implementation for LRC to TTML conversion
//

import Foundation

/// Converts raw lyrics to TTML format using native Swift implementation
nonisolated final class TTMLConverter: @unchecked Sendable {

    static let shared = TTMLConverter()

    private init() {}

    /// Convert raw lyrics to TTML (without translation)
    func convertToTTML(
        rawLyrics: String,
        stripMetadata: Bool = true,
        fixTimingIssues: Bool = true
    ) async throws -> String {
        return try await LRCConverterService.shared.convertToTTML(
            lrcContent: rawLyrics,
            stripMetadata: stripMetadata,
            fixTimingIssues: fixTimingIssues
        )
    }

    /// Convert raw lyrics with translation to TTML
    func convertToTTMLWithTranslation(
        origLyrics: String,
        transLyrics: String,
        stripMetadata: Bool = true,
        fixTimingIssues: Bool = true
    ) async throws -> String {
        return try await LRCConverterService.shared.convertToTTMLWithTranslation(
            origContent: origLyrics,
            transContent: transLyrics,
            stripMetadata: stripMetadata,
            fixTimingIssues: fixTimingIssues
        )
    }
}

// MARK: - Error Types

enum TTMLConversionError: LocalizedError {
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .conversionFailed(let msg):
            return String(format: NSLocalizedString("error.ttml.failed", comment: ""), msg)
        }
    }
}
