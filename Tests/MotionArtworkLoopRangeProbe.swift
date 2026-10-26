import Foundation
import AVFoundation

/// Compile with the production MotionArtworkLoopRange declaration. Arguments
/// are real materialized square/tall assets whose native edit-list range is 0–20.
@main
struct MotionArtworkLoopRangeProbe {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else {
            throw NSError(domain: "MotionArtworkLoopRangeProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass real materialized MP4 paths"])
        }
        for path in CommandLine.arguments.dropFirst() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let rawFragmentRange = CMTimeRange(start: CMTime(seconds: 10, preferredTimescale: 600), duration: CMTime(seconds: 20, preferredTimescale: 600))
            guard let range = await MotionArtworkLoopRange.load(asset: asset, fallback: rawFragmentRange),
                  abs(range.start.seconds) < 0.01, abs(range.duration.seconds - 20) < 0.01 else {
                throw NSError(domain: "MotionArtworkLoopRangeProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native loop must be 0–20 despite raw metadata 10–30: \(path)"])
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 64, height: 64)
            let frame = try await generator.image(at: CMTimeAdd(range.start, CMTime(seconds: 1, preferredTimescale: 600)))
            let result: [String: Any] = ["file": URL(fileURLWithPath: path).lastPathComponent, "loopStart": range.start.seconds, "loopEnd": CMTimeRangeGetEnd(range).seconds, "decodedWidth": frame.image.width, "decodedHeight": frame.image.height]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        }
    }
}
