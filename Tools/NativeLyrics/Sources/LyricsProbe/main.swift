import AppKit
import NativeLyrics
import ImageIO
import UniformTypeIdentifiers

@MainActor func run() throws {
    let args = CommandLine.arguments
    if args.count >= 3, args[1] == "--decode-only" {
        for path in args.dropFirst(2) {
            let url = URL(fileURLWithPath: path)
            do {
                let document = try TTMLDecoder().decode(Data(contentsOf: url))
                print("OK\t\(document.groups.count)\t\(String(format: "%.3f", document.duration))\t\(path)")
            } catch {
                print("ERR\t\(error.localizedDescription)\t\(path)")
            }
        }
        return
    }
    guard args.count>=3 else { throw LyricsError.invalidTTML("Usage: LyricsProbe file.ttml output-directory [time=8] [width=760] [height=720]") }
    let url = URL(fileURLWithPath:args[1]), output = URL(fileURLWithPath:args[2],isDirectory:true)
    let time = args.count>3 ? Double(args[3]) ?? 8 : 8
    let width = args.count>4 ? Double(args[4]) ?? 760 : 760, height = args.count>5 ? Double(args[5]) ?? 720 : 720
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    _ = NSApplication.shared
    let view = LyricsView(frame:NSRect(x:0,y:0,width:width,height:height)); view.automaticDisplayUpdates = false
    let paused = args.contains("--paused")
    if args.contains("--core") { view.configuration.surface = .coreReference }
    if args.contains("--upstream") { view.configuration.profile = .upstream }
    try view.load(ttml:Data(contentsOf:url),time:paused ? time : 0,playing:!paused,hostTime:0)
    var frames: [LyricsFrame] = []
    for tick in 0...Int((paused ? 3 : max(0,time))*120) { frames.append(view.render(at:Double(tick)/120)) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    try encoder.encode(frames).write(to:output.appendingPathComponent("trace.json"))
    try encoder.encode(view.diagnosticTimings).write(to:output.appendingPathComponent("timing.json"))
    if let image = view.snapshotImage(), let dest = CGImageDestinationCreateWithURL(output.appendingPathComponent("frame.png") as CFURL,UTType.png.identifier as CFString,1,nil) {
        CGImageDestinationAddImage(dest,image,nil); guard CGImageDestinationFinalize(dest) else { throw LyricsError.invalidTTML("PNG export failed") }
    }
    let costs = frames.dropFirst().map(\.renderMilliseconds).sorted()
    let summary: [String:Any] = ["frames":frames.count,"groups":view.document?.groups.count ?? 0,"renderP95Milliseconds":costs.isEmpty ? 0 : costs[Int(Double(costs.count-1)*0.95)],"cacheBytes":frames.last?.glyphCacheBytes ?? 0,"output":output.path]
    let data = try JSONSerialization.data(withJSONObject:summary,options:.sortedKeys)
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}
MainActor.assumeIsolated {
    do { try run() } catch { FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)); exit(1) }
}
