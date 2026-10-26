import AppKit
import Foundation

@main
struct FastArtworkMemoryCacheGenerationRegressionTests {
    @MainActor
    static func main() {
        let cache = FastArtworkMemoryCache.shared
        cache.removeAll()
        let staleGeneration = cache.currentGeneration()
        let image = NSImage(size: NSSize(width: 32, height: 32))

        cache.removeAll()
        expect(
            !cache.store(image, forKey: "stale-generation", generation: staleGeneration),
            "A write from before clear must be rejected"
        )
        expect(
            cache.image(forKey: "stale-generation") == nil,
            "A rejected stale write must not become visible"
        )

        let currentGeneration = cache.currentGeneration()
        expect(
            cache.store(image, forKey: "current-generation", generation: currentGeneration),
            "A write from the current generation must be accepted"
        )
        expect(
            cache.image(forKey: "current-generation") != nil,
            "An accepted write must be readable"
        )
        cache.removeAll()
        print("FastArtworkMemoryCacheGenerationRegressionTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FastArtworkMemoryCacheGenerationRegressionTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
