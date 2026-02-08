import Foundation

struct LddcFetchError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func fetchLrcViaCLI(title: String, artist: String?) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

    var args = ["lddc-fetch", "--title", title, "--mode", "verbatim", "--translation", "provider"]
    if let artist, !artist.isEmpty { args += ["--artist", artist] }
    process.arguments = args

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()
    process.waitUntilExit()

    let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    if process.terminationStatus != 0 {
        throw LddcFetchError(message: err.isEmpty ? "lddc-fetch failed" : err)
    }
    return out
}

// Example
do {
    let lrc = try fetchLrcViaCLI(title: "夜に駆ける", artist: "YOASOBI")
    print(lrc)
} catch {
    print("ERROR:", error)
}

