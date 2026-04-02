//
//  TTMLConverter.swift
//  myPlayer2
//
//  kmgccc_player - Raw Lyrics to TTML Converter
//  Calls Python scripts to convert raw lyrics to TTML format.
//

import Foundation

/// Converts raw lyrics to TTML format using bundled Python scripts.
nonisolated final class TTMLConverter: @unchecked Sendable {

    static let shared = TTMLConverter()

    private init() {}

    /// Convert raw lyrics to TTML (without translation).
    func convertToTTML(rawLyrics: String, stripMetadata: Bool = true) async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let inputFile = tempDir.appendingPathComponent("input_\(UUID().uuidString).lrc")
        let ttmlFile = tempDir.appendingPathComponent("output_\(UUID().uuidString).ttml")

        defer {
            try? FileManager.default.removeItem(at: inputFile)
            try? FileManager.default.removeItem(at: ttmlFile)
        }

        // Write raw lyrics to temp file
        try rawLyrics.write(to: inputFile, atomically: true, encoding: .utf8)

        // Find script
        guard let scriptURL = findScript(name: "lrc_to_ttml.py") else {
            throw TTMLConversionError.scriptNotFound("lrc_to_ttml.py")
        }

        // Run conversion
        var args = ["-i", inputFile.path, "-o", ttmlFile.path]
        if !stripMetadata {
            args.append("--no-strip-metadata")
        }

        try await runPythonScript(
            scriptURL: scriptURL,
            args: args
        )

        // Read result
        guard FileManager.default.fileExists(atPath: ttmlFile.path) else {
            throw TTMLConversionError.outputNotGenerated
        }

        return try String(contentsOf: ttmlFile, encoding: .utf8)
    }

    /// Convert raw lyrics with translation to TTML.
    func convertToTTMLWithTranslation(
        origLyrics: String,
        transLyrics: String,
        stripMetadata: Bool = true
    ) async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let origFile = tempDir.appendingPathComponent("orig_\(UUID().uuidString).lrc")
        let transFile = tempDir.appendingPathComponent("trans_\(UUID().uuidString).lrc")
        let ttmlFile = tempDir.appendingPathComponent("output_\(UUID().uuidString).ttml")

        defer {
            try? FileManager.default.removeItem(at: origFile)
            try? FileManager.default.removeItem(at: transFile)
            try? FileManager.default.removeItem(at: ttmlFile)
        }

        // Write lyrics files
        try origLyrics.write(to: origFile, atomically: true, encoding: .utf8)
        try transLyrics.write(to: transFile, atomically: true, encoding: .utf8)

        // Find script
        guard let scriptURL = findScript(name: "lrc_to_ttml_with_translation.py") else {
            throw TTMLConversionError.scriptNotFound("lrc_to_ttml_with_translation.py")
        }

        // Run conversion
        var args = ["-i", origFile.path, "-t", transFile.path, "-o", ttmlFile.path]
        if !stripMetadata {
            args.append("--no-strip-metadata")
        }

        try await runPythonScript(
            scriptURL: scriptURL,
            args: args
        )

        // Read result
        guard FileManager.default.fileExists(atPath: ttmlFile.path) else {
            throw TTMLConversionError.outputNotGenerated
        }

        return try String(contentsOf: ttmlFile, encoding: .utf8)
    }

    // MARK: - Private Methods

    private func findScript(name: String) -> URL? {
        // Try bundle (SwiftData/App Sandbox means we cannot rely on repo-relative paths at runtime).
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension.isEmpty ? nil : ns.pathExtension

        // Common: file is copied (flattened) into Contents/Resources.
        if let url = Bundle.main.url(forResource: base, withExtension: ext) {
            return url
        }

        // Optional subfolders (if you later decide to preserve structure via folder references).
        if let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "Tools") {
            return url
        }
        if let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "LDDC") {
            return url
        }

        // Development path - repo checkout
        if let coreRoot = locateLDDCCoreRoot() {
            let candidate = coreRoot.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func runPythonScript(scriptURL: URL, args: [String]) async throws {
        let process = Process()

        // Find Python
        let coreRoot = locateLDDCCoreRoot()
        let venvPaths = [
            coreRoot?.appendingPathComponent(".venv/bin/python").path,
            coreRoot?.appendingPathComponent(".venv/bin/python3").path,
        ].compactMap { $0 }
        let pythonPaths = [
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ]
        var pythonPath: String?
        for path in (venvPaths + pythonPaths) {
            if FileManager.default.isExecutableFile(atPath: path) {
                pythonPath = path
                break
            }
        }

        guard let python = pythonPath else {
            throw TTMLConversionError.pythonNotFound
        }

        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [scriptURL.path] + args
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

                guard process.terminationStatus == 0 else {
                    let errorMessage =
                        String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? NSLocalizedString("error.ttml.unknown", comment: "")
                    continuation.resume(
                        throwing: TTMLConversionError.conversionFailed(errorMessage))
                    return
                }

                continuation.resume()
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func locateLDDCCoreRoot() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let bases: [URL] = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath),
            home.appendingPathComponent("Documents/vscode/player/myPlayer2", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home,
        ]
        let relativeCandidates = [
            "LDDC_Fetch_Core",
            "LDDC-main/LDDC_Fetch_Core",
        ]

        for base in bases {
            var cur = base
            for _ in 0..<8 {
                for rel in relativeCandidates {
                    let root = cur.appendingPathComponent(rel, isDirectory: true)
                    let marker =
                        root
                        .appendingPathComponent("src", isDirectory: true)
                        .appendingPathComponent("lddc_fetch_core", isDirectory: true)
                    if fileManager.fileExists(atPath: marker.path) {
                        return root
                    }
                }
                cur.deleteLastPathComponent()
            }
        }
        return nil
    }
}

// MARK: - Error Types

enum TTMLConversionError: LocalizedError {
    case scriptNotFound(String)
    case pythonNotFound
    case outputNotGenerated
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound(let name):
            return String(
                format: NSLocalizedString("error.ttml.script_not_found", comment: ""), name)
        case .pythonNotFound:
            return NSLocalizedString("error.ttml.python_not_found", comment: "")
        case .outputNotGenerated:
            return NSLocalizedString("error.ttml.output_not_found", comment: "")
        case .conversionFailed(let msg):
            return String(format: NSLocalizedString("error.ttml.failed", comment: ""), msg)
        }
    }
}
