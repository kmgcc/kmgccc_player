//
//  SharedCoreImageContext.swift
//  kmgccc_player
//
//  The single Core Image context for offscreen artwork and skin rendering.
//

import CoreImage

/// Core Image compiles Metal compute programs for the filter graphs a context
/// renders, and the GPU driver keeps every compiled program for the life of the
/// process. Contexts that were created per render, or dropped on routine cache
/// purges, compiled their graphs again on the next render, while memory graphs
/// of a listening session showed thousands of driver programs accumulating.
///
/// Skins and backgrounds therefore share this one context for the whole process,
/// and nothing clears its caches: its intermediates are not cached, so
/// `clearCaches()` frees no memory and only drops the compiled programs, which
/// the next render compiles again while the driver keeps the old copies.
enum SharedCoreImageContext {
    nonisolated static let context = CIContext(options: options)

    /// `KMGCCC_CI_MEMORY_LIMIT_MB` caps the memory the context allocates for a
    /// render; measurement runs compare it with the system default.
    private nonisolated static var options: [CIContextOption: Any] {
        var options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .useSoftwareRenderer: false,
        ]
        if let raw = ProcessInfo.processInfo.environment["KMGCCC_CI_MEMORY_LIMIT_MB"],
           let megabytes = Int(raw), megabytes > 0 {
            options[.memoryTarget] = megabytes
        }
        return options
    }
}
