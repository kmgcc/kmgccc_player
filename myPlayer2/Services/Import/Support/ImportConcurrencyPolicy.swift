//
//  ImportConcurrencyPolicy.swift
//  myPlayer2
//

import Foundation

nonisolated enum ImportConcurrencyPolicy {
    static func duplicatePreparation(for count: Int) -> Int {
        bounded(count, minimum: 4, maximum: 12) { cpuCount in
            cpuCount * 2
        }
    }

    static func ncmConversion(for count: Int) -> Int {
        bounded(count, minimum: 2, maximum: 6) { cpuCount in
            cpuCount
        }
    }

    static func trackImport(for count: Int) -> Int {
        bounded(count, minimum: 3, maximum: 6) { cpuCount in
            cpuCount
        }
    }

    static func immediateEnrichment(for count: Int) -> Int {
        bounded(count, minimum: 2, maximum: 4) { cpuCount in
            max(2, cpuCount / 2)
        }
    }

    private static func bounded(
        _ count: Int,
        minimum: Int,
        maximum: Int,
        cpuScaling: (Int) -> Int
    ) -> Int {
        guard count > 0 else { return 1 }
        let cpuCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(count, min(maximum, max(minimum, cpuScaling(cpuCount))))
    }
}
