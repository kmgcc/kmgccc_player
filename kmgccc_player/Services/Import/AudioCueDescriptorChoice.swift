import Foundation

nonisolated struct AudioCueDescriptorChoice: Sendable {
    let file: ImportDiscoveredFile
    let descriptors: [URL]
}
