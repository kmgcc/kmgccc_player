import Foundation

nonisolated struct CrashReportSanitizer: Sendable {
    static let redactionVersion = "1"

    private let libraryRootURL: URL
    private let appDataRootURL: URL

    init(libraryRootURL: URL, appDataRootURL: URL = CrashReportPaths.applicationSupport) {
        self.libraryRootURL = libraryRootURL
        self.appDataRootURL = appDataRootURL
    }

    func sanitize(_ input: CrashReportEnvelope) -> CrashReportEnvelope {
        var report = input
        var counts: [String: Int] = [:]

        report.exception.name = report.exception.name.map {
            sanitizeText($0, maxLength: 256, counts: &counts)
        }
        report.exception.reason = report.exception.reason.map {
            sanitizeText($0, maxLength: 4_096, counts: &counts)
        }

        report.threads = report.threads.prefix(128).map { thread in
            var value = thread
            value.name = value.name.map { sanitizeText($0, maxLength: 256, counts: &counts) }
            value.queueName = value.queueName.map { sanitizeText($0, maxLength: 256, counts: &counts) }
            value.frames = value.frames.prefix(256).map { frame in
                var sanitized = frame
                sanitized.imageName = sanitized.imageName.map {
                    sanitizeImageName($0, counts: &counts)
                }
                sanitized.symbolName = sanitized.symbolName.map {
                    sanitizeText($0, maxLength: 1_024, counts: &counts)
                }
                return sanitized
            }
            return value
        }

        report.binaryImages = report.binaryImages.prefix(512).map { image in
            var value = image
            value.basename = sanitizeImageName(value.basename, counts: &counts)
            value.version = value.version.map { sanitizeText($0, maxLength: 128, counts: &counts) }
            return value
        }

        if var context = report.appContext {
            context.selectedSkinIdentifier = context.selectedSkinIdentifier.map {
                sanitizeIdentifier($0, maxLength: 128, counts: &counts)
            }
            context.lastOperationCategory = context.lastOperationCategory.map {
                sanitizeIdentifier($0, maxLength: 128, counts: &counts)
            }
            report.appContext = context
        }

        report.breadcrumbs = report.breadcrumbs.suffix(100).map { breadcrumb in
            var value = breadcrumb
            value.category = sanitizeIdentifier(value.category, maxLength: 64, counts: &counts)
            value.action = sanitizeIdentifier(value.action, maxLength: 96, counts: &counts)
            var metadata: [String: CrashDiagnosticValue] = [:]
            for (key, item) in value.metadata.prefix(20) {
                let cleanKey = sanitizeIdentifier(key, maxLength: 64, counts: &counts)
                metadata[cleanKey] = sanitizeDiagnosticValue(item, key: key, counts: &counts)
            }
            value.metadata = metadata
            return value
        }

        report.userDescription = report.userDescription.map {
            sanitizeText($0.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 1_000, counts: &counts)
        }
        report.clientRedaction = CrashRedactionInfo(
            version: Self.redactionVersion,
            replacementCounts: counts
        )
        return report
    }

    func sanitizePath(_ rawValue: String, counts: inout [String: Int]) -> String {
        let value = stripControlCharacters(rawValue.trimmingCharacters(in: .whitespacesAndNewlines), counts: &counts)
            .replacingOccurrences(of: "\\", with: "/")

        if value == "$MUSIC_LIBRARY" || value.hasPrefix("$MUSIC_LIBRARY/") {
            return sanitizePlaceholderPath(value, placeholder: "$MUSIC_LIBRARY", counts: &counts)
        }
        if value == "$APP_DATA" || value.hasPrefix("$APP_DATA/") {
            return sanitizePlaceholderPath(value, placeholder: "$APP_DATA", counts: &counts)
        }

        let standardized = URL(fileURLWithPath: value)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let path = standardized.path
        let libraryRoot = libraryRootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let appDataRoot = appDataRootURL.standardizedFileURL.resolvingSymlinksInPath().path

        if let relative = relativePath(path, inside: libraryRoot) {
            increment("music_library_path", counts: &counts)
            return sanitizePlaceholderPath("$MUSIC_LIBRARY/\(relative)", placeholder: "$MUSIC_LIBRARY", counts: &counts)
        }
        if let relative = relativePath(path, inside: appDataRoot) {
            increment("app_data_path", counts: &counts)
            return sanitizePlaceholderPath("$APP_DATA/\(relative)", placeholder: "$APP_DATA", counts: &counts)
        }
        if isAllowedSystemPath(path) {
            return String(path.prefix(1_024))
        }

        increment("external_path", counts: &counts)
        return externalPathPlaceholder(path)
    }

    private func sanitizeDiagnosticValue(
        _ value: CrashDiagnosticValue,
        key: String,
        counts: inout [String: Int]
    ) -> CrashDiagnosticValue {
        guard case .string(let string) = value else { return value }
        let normalizedKey = key.lowercased().replacingOccurrences(of: "_", with: "")
        let pathKeys = ["path", "filepath", "url", "fileurl", "sourceurl"]
        if pathKeys.contains(normalizedKey) {
            return .string(sanitizePath(string, counts: &counts))
        }
        return .string(sanitizeText(string, maxLength: 1_024, counts: &counts))
    }

    private func sanitizeImageName(_ value: String, counts: inout [String: Int]) -> String {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let basename = normalized.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? normalized
        if basename != value {
            increment("image_path_removed", counts: &counts)
        }
        return sanitizeText(basename, maxLength: 256, counts: &counts)
    }

    private func sanitizeIdentifier(_ value: String, maxLength: Int, counts: inout [String: Int]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:+-"))
        var result = stripControlCharacters(value, counts: &counts)
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
            increment("identifier_truncated", counts: &counts)
        }
        return result.isEmpty ? "unknown" : result
    }

    private func sanitizeText(_ value: String, maxLength: Int, counts: inout [String: Int]) -> String {
        var result = stripControlCharacters(value, counts: &counts)
        result = replace(
            pattern: #"(?i)\b(authorization|cookie|set-cookie|token|access[_-]?token|refresh[_-]?token|secret|password|passwd|api[_-]?key)\b(\s*[:=]\s*)([^\s,;]+)"#,
            in: result,
            countsKey: "secret",
            counts: &counts
        ) { match, source in
            let key = source.substring(with: match.range(at: 1))
            let separator = source.substring(with: match.range(at: 2))
            return "\(key)\(separator)<REDACTED>"
        }
        result = replace(
            pattern: #"(?<![\w.+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?![\w.-])"#,
            in: result,
            countsKey: "email",
            counts: &counts
        ) { _, _ in "<EMAIL_REDACTED>" }
        result = replace(
            pattern: #"https?://[^\s?#]+(?:\?[^\s#]*)?(?:#[^\s]*)?"#,
            in: result,
            countsKey: "url_details",
            counts: &counts
        ) { match, source in
            let original = source.substring(with: match.range)
            guard var components = URLComponents(string: original) else { return original }
            guard components.query != nil || components.fragment != nil else { return original }
            components.query = nil
            components.fragment = nil
            return components.string ?? original
        }
        result = replacePaths(in: result, counts: &counts)

        if result.count > maxLength {
            result = String(result.prefix(max(0, maxLength - 1))) + "…"
            increment("text_truncated", counts: &counts)
        }
        return result
    }

    private func sanitizePlaceholderPath(
        _ value: String,
        placeholder: String,
        counts: inout [String: Int]
    ) -> String {
        guard value != placeholder else { return placeholder }
        let prefix = placeholder + "/"
        guard value.hasPrefix(prefix) else { return placeholder + "/<INVALID_RELATIVE_PATH>" }
        let components = String(value.dropFirst(prefix.count)).split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.count <= 32,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            increment("invalid_placeholder_path", counts: &counts)
            return placeholder + "/<INVALID_RELATIVE_PATH>"
        }
        let sanitized = components.map {
            sanitizeText(String($0), maxLength: 160, counts: &counts)
        }.joined(separator: "/")
        let result = prefix + sanitized
        if result.count > 768 {
            increment("path_truncated", counts: &counts)
            return String(result.prefix(767)) + "…"
        }
        return result
    }

    private func relativePath(_ path: String, inside root: String) -> String? {
        guard path != root else { return "<ROOT>" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func isAllowedSystemPath(_ path: String) -> Bool {
        ["/System/", "/usr/lib/", "/usr/libexec/", "/Library/Apple/System/"].contains {
            path.hasPrefix($0)
        }
    }

    private func externalPathPlaceholder(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let safeExtension = ext.range(of: #"^[a-z0-9]{1,12}$"#, options: .regularExpression) != nil
            ? " ext=.\(ext)"
            : ""
        return "<EXTERNAL_PATH\(safeExtension) depth=\(components.count)>"
    }

    private func stripControlCharacters(_ value: String, counts: inout [String: Int]) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            let number = scalar.value
            if number <= 0x08 || (0x0B...0x0C).contains(number) || (0x0E...0x1F).contains(number) {
                return false
            }
            if (0x7F...0x9F).contains(number) || (0x200B...0x200F).contains(number)
                || (0x202A...0x202E).contains(number) || number == 0x2060 || number == 0xFEFF {
                return false
            }
            return true
        }
        let result = String(String.UnicodeScalarView(filtered))
        if result != value { increment("control_character", counts: &counts) }
        return result
    }

    private func replace(
        pattern: String,
        in value: String,
        countsKey: String?,
        counts: inout [String: Int],
        transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let source = value as NSString
        let matches = expression.matches(in: value, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return value }
        if let countsKey { increment(countsKey, by: matches.count, counts: &counts) }
        let mutable = NSMutableString(string: value)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: transform(match, source))
        }
        return mutable as String
    }

    private func replacePaths(in value: String, counts: inout [String: Int]) -> String {
        let pattern = #"(?:\$MUSIC_LIBRARY|\$APP_DATA|/(?:Users|Volumes|System|usr|Library|private|var|tmp))(?:/[^\s\"'<>]*)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let source = value as NSString
        let matches = expression.matches(in: value, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return value }
        let mutable = NSMutableString(string: value)
        for match in matches.reversed() {
            var path = source.substring(with: match.range)
            var suffix = ""
            while let last = path.last, ".,;:)]}".contains(last) {
                suffix.insert(last, at: suffix.startIndex)
                path.removeLast()
            }
            mutable.replaceCharacters(in: match.range, with: sanitizePath(path, counts: &counts) + suffix)
        }
        return mutable as String
    }

    private func increment(_ key: String, by amount: Int = 1, counts: inout [String: Int]) {
        counts[key, default: 0] += amount
    }
}
