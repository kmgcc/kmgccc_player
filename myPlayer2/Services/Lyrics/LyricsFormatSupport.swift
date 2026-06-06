//
//  LyricsFormatSupport.swift
//  myPlayer2
//
//  Lightweight lyric format detection and TTML validation for app-side storage gates.
//

import Foundation

nonisolated enum LyricsFormatSupport {
    static func normalizedTTMLText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, validateTTML(trimmed).isValid else { return nil }
        return trimmed
    }

    static func validateManualTTML(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let result = validateTTML(trimmed)
        return result.isValid ? nil : result.message
    }

    static func validateTTML(_ text: String) -> TTMLValidationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid("歌词为空")
        }
        guard looksLikeTTML(trimmed) else {
            return .invalid("仅支持 TTML 歌词，请通过歌词搜索或自动导入流程转换 LRC/TXT。")
        }

        guard trimmed.range(of: #"<(?:\w+:)?tt(?:\s|>|/)"#, options: [.regularExpression, .caseInsensitive]) != nil,
              trimmed.range(of: #"</(?:\w+:)?tt\s*>"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return .invalid("未找到 TTML <tt> 根节点")
        }
        guard trimmed.range(of: #"<(?:\w+:)?body(?:\s|>|/)"#, options: [.regularExpression, .caseInsensitive]) != nil,
              trimmed.range(of: #"</(?:\w+:)?body\s*>"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return .invalid("TTML 缺少 <body> 节点")
        }
        return .valid
    }

    static func looksLikeTTML(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: #"<(?:\w+:)?tt(?:\s|>|/)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func looksLikeLRC(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        var timestampLineCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.range(of: #"\[(?:\d{1,3}):(?:[0-5]?\d)(?:[\.,]\d{1,3})?\]"#, options: .regularExpression) != nil {
                timestampLineCount += 1
                if timestampLineCount >= 1 { return true }
            }
        }
        return false
    }
}

nonisolated enum TTMLValidationResult: Equatable {
    case valid
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var message: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}
