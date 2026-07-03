import AppKit
import Darwin
import Foundation

@main
struct ColorGoldenMasterMain {
    static func main() async {
        let code = await MainActor.run {
            ColorGoldenMasterCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        }
        exit(Int32(code))
    }
}

enum ColorGoldenMasterCLI {
    static let toolDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tools/ColorGoldenMaster", isDirectory: true)
    static let baselineURL = toolDirectory
        .appendingPathComponent("Baselines/color-golden-master.txt")
    static let generatedURL = toolDirectory
        .appendingPathComponent(".generated/color-golden-master.current.txt")
    static let accentParityURL = toolDirectory
        .appendingPathComponent(".generated/accent-parity-report.txt")
    static let accentReviewURL = toolDirectory
        .appendingPathComponent(".generated/accent-parity-review.html")
    static let bkParityURL = toolDirectory
        .appendingPathComponent(".generated/bk-parity-report.txt")
    static let bkReviewURL = toolDirectory
        .appendingPathComponent(".generated/bk-parity-review.html")
    static let ledParityURL = toolDirectory
        .appendingPathComponent(".generated/led-parity-report.txt")
    static let ledReviewURL = toolDirectory
        .appendingPathComponent(".generated/led-parity-review.html")
    static let lyricsParityURL = toolDirectory
        .appendingPathComponent(".generated/lyrics-parity-report.txt")
    static let lyricsReviewURL = toolDirectory
        .appendingPathComponent(".generated/lyrics-parity-review.html")
    static let readabilityParityURL = toolDirectory
        .appendingPathComponent(".generated/readability-parity-report.txt")

    static func run(arguments: [String]) -> Int {
        let command = arguments.first ?? "help"
        do {
            switch command {
            case "generate":
                let snapshot = try stableSnapshot()
                try write(snapshot, to: baselineURL)
                print("generated baseline: \(baselineURL.path)")
                print("samples: \(try ColorGoldenMasterSamples.all().count)")
                return 0

            case "verify":
                guard FileManager.default.fileExists(atPath: baselineURL.path) else {
                    throw GoldenMasterError.missingGolden(path: baselineURL.path)
                }
                let snapshot = try stableSnapshot()
                let baseline = try String(contentsOf: baselineURL, encoding: .utf8)
                if baseline == snapshot {
                    print("golden verify passed: \(baselineURL.path)")
                    return 0
                }
                try write(snapshot, to: generatedURL)
                print("golden verify failed: baseline differs from current output")
                print("baseline: \(baselineURL.path)")
                print("current:  \(generatedURL.path)")
                print("diff:     diff -u \"\(baselineURL.path)\" \"\(generatedURL.path)\"")
                return 1

            case "snapshot":
                let snapshot = try stableSnapshot()
                print(snapshot, terminator: "")
                return 0

            case "accent-parity":
                let report = try ColorGoldenMasterAccentParity.render()
                try write(report.text, to: accentParityURL)
                print("accent parity report: \(accentParityURL.path)")
                print("summary: \(report.summary.statusLine)")
                if report.summary.blocker > 0 {
                    return 1
                }
                return 0

            case "accent-review":
                let html = try ColorGoldenMasterAccentParity.renderHTML()
                try write(html, to: accentReviewURL)
                print("accent review artifact: \(accentReviewURL.path)")
                return 0

            case "bk-parity":
                let report = try ColorGoldenMasterBKParity.render()
                try write(report.text, to: bkParityURL)
                print("BK parity report: \(bkParityURL.path)")
                print("summary: \(report.summary.statusLine)")
                if report.summary.blocker > 0 {
                    return 1
                }
                return 0

            case "bk-review":
                let html = try ColorGoldenMasterBKParity.renderHTML()
                try write(html, to: bkReviewURL)
                print("BK review artifact: \(bkReviewURL.path)")
                return 0

            case "led-parity":
                let report = try ColorGoldenMasterLEDParity.render()
                try write(report.text, to: ledParityURL)
                print("LED parity report: \(ledParityURL.path)")
                print("summary: \(report.summary.statusLine)")
                if report.summary.blocker > 0 {
                    return 1
                }
                return 0

            case "led-review":
                let html = try ColorGoldenMasterLEDParity.renderHTML()
                try write(html, to: ledReviewURL)
                print("LED review artifact: \(ledReviewURL.path)")
                return 0

            case "lyrics-parity":
                let report = try ColorGoldenMasterLyricsParity.render()
                try write(report.text, to: lyricsParityURL)
                print("lyrics parity report: \(lyricsParityURL.path)")
                print("summary: \(report.summary.statusLine)")
                return 0

            case "lyrics-review":
                let html = try ColorGoldenMasterLyricsParity.renderHTML()
                try write(html, to: lyricsReviewURL)
                print("lyrics review artifact: \(lyricsReviewURL.path)")
                return 0

            case "readability-parity":
                let report = try ColorGoldenMasterReadabilityParity.render()
                try write(report, to: readabilityParityURL)
                print("readability parity report: \(readabilityParityURL.path)")
                return 0

            case "accent-review-export":
                guard arguments.count >= 2 else {
                    print("accent-review-export requires a review session JSON path", to: &standardError)
                    printHelp()
                    return 2
                }
                let result = try AccentParityReviewArtifact.exportReviewSession(path: arguments[1])
                print("accent review export: \(result.outputDirectory)")
                print("decisions: \(result.decisionCount)")
                print("approved delta candidates: \(result.approvedCount)")
                print("needs tuning: \(result.needsTuningCount)")
                print("legacy better: \(result.legacyBetterCount)")
                print("undecided: \(result.undecidedCount)")
                print("approved manifest candidate: \(result.approvedURL)")
                print("needs tuning list: \(result.needsTuningURL)")
                print("legacy better list: \(result.legacyBetterURL)")
                print("undecided list: \(result.undecidedURL)")
                print("summary: \(result.summaryURL)")
                return 0

            case "refresh-extended-corpus":
                let options = try parseRefreshOptions(Array(arguments.dropFirst()))
                let manifest = try ExtendedCorpusStore.refresh(
                    seed: options.seed,
                    targetCount: options.targetCount
                )
                print("refreshed extended corpus manifest: \(ExtendedCorpusStore.manifestURL.path)")
                print("seed: \(manifest.randomSeed)")
                print("source artworks: \(manifest.sourceArtworkCount)")
                print("excluded Golden Gate artworks: \(manifest.excludedGoldenGateTrackCount)")
                print("decoded artworks: \(manifest.decodedArtworkCount)")
                print("candidate artworks after stability screening: \(manifest.candidateArtworkCount)")
                print("excluded unstable rank-tie artworks: \(manifest.excludedUnstableRankTieCount)")
                print("failed artworks: \(manifest.failedArtworkCount)")
                print("selected samples: \(manifest.selectedCount)")
                print("coverage: \(ExtendedCorpusStore.coverageLine(from: manifest))")
                return 0

            case "help", "--help", "-h":
                printHelp()
                return 0

            default:
                print("unknown command: \(command)")
                printHelp()
                return 2
            }
        } catch {
            print("ColorGoldenMaster error: \(error)", to: &standardError)
            return 1
        }
    }

    private static func parseRefreshOptions(_ arguments: [String]) throws -> (
        seed: String,
        targetCount: Int
    ) {
        var seed: String?
        var targetCount = 130
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--seed":
                guard index + 1 < arguments.count else {
                    throw GoldenMasterError.refreshExtendedCorpusRequiresSeed
                }
                seed = arguments[index + 1]
                index += 2
            case "--target":
                guard index + 1 < arguments.count,
                      let parsed = Int(arguments[index + 1])
                else {
                    print("invalid --target value", to: &standardError)
                    throw GoldenMasterError.refreshExtendedCorpusRequiresSeed
                }
                targetCount = parsed
                index += 2
            default:
                print("unknown refresh-extended-corpus option: \(argument)", to: &standardError)
                throw GoldenMasterError.refreshExtendedCorpusRequiresSeed
            }
        }

        guard let seed, !seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoldenMasterError.refreshExtendedCorpusRequiresSeed
        }
        return (seed, targetCount)
    }

    private static func stableSnapshot() throws -> String {
        let first = try ColorGoldenMasterSnapshot.render()
        let second = try ColorGoldenMasterSnapshot.render()
        guard first == second else {
            try? write(first, to: generatedURL)
            throw GoldenMasterError.unstableOutput
        }
        return first
    }

    private static func write(_ text: String, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw GoldenMasterError.writeFailed(path: url.path, message: String(describing: error))
        }
    }

    private static func printHelp() {
        print("""
        ColorGoldenMaster

        Commands:
          generate   Generate and approve Tools/ColorGoldenMaster/Baselines/color-golden-master.txt
          verify     Generate current output and compare it with the approved baseline
          snapshot   Print current stable snapshot to stdout
          accent-parity
                     Write controlled legacy/candidate accent diff report
          accent-review
                     Write interactive local accent review HTML
          bk-parity
                     Write controlled legacy-HSB / candidate-OKLCH BK diff report
          bk-review
                     Write local BK role/layer review HTML
          led-parity
                     Write controlled legacy/candidate LED OKLCH parity report
          led-review
                     Write local LED role/level review HTML
          lyrics-parity
                     Write lyric legacy parity and Web adapter derived-role report
          lyrics-review
                     Write local lyric parity review HTML
          accent-review-export <session.json>
                     Export a downloaded accent review session into approved-delta and tuning lists
          refresh-extended-corpus --seed <seed> [--target 130]
                     Rebuild the frozen extended real-cover manifest
          help       Show this help
        """)
    }
}

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

var standardError = StandardError()
