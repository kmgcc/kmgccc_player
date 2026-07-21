//
//  DeviceTelemetryProvider.swift
//  myPlayer2
//
//  kmgccc_player - Gathers raw hardware inputs (sysctl / IORegistry / ProcessInfo)
//  and hands them to `DeviceTelemetryClassifier` to produce the coarse anonymous
//  device snapshot. Only the classified, coarse-grained result leaves this type.
//

import Foundation
import IOKit

/// Coarse, anonymous device snapshot uploaded alongside basic telemetry.
/// Every field is product-family / generation level — nothing here identifies a
/// specific machine or user.
struct DeviceTelemetrySnapshot: Equatable, Sendable {
    let deviceFamily: String
    let chipTier: String
    let memoryGB: Int?
    let osMajor: String
}

enum DeviceTelemetryProvider {
    /// Compute the current coarse device snapshot. Cheap; intended to be called
    /// at most a handful of times per launch and cached by the caller.
    static func current() -> DeviceTelemetrySnapshot {
        let modelIdentifier = sysctlString("hw.model")
        let brandString = sysctlString("machdep.cpu.brand_string")
        let marketingName = ioRegistryProductString("product-name")
        let socName = ioRegistryProductString("product-soc-name")

        let family = DeviceTelemetryClassifier.deviceFamily(
            fromCandidates: [marketingName, modelIdentifier]
        )
        let chipTier = DeviceTelemetryClassifier.chipTier(
            fromCandidates: [socName, brandString]
        )
        let memoryGB = DeviceTelemetryClassifier.memoryGB(
            fromBytes: ProcessInfo.processInfo.physicalMemory
        )
        let osMajor = DeviceTelemetryClassifier.osMajor(
            fromMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )

        return DeviceTelemetrySnapshot(
            deviceFamily: family,
            chipTier: chipTier,
            memoryGB: memoryGB,
            osMajor: osMajor
        )
    }

    // MARK: - Raw input helpers

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    /// Apple Silicon exposes both a marketing product name and a coarse SoC name
    /// under `IODeviceTree:/product` (usually NUL-terminated UTF-8 in CFData).
    private static func ioRegistryProductString(_ key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        guard let property = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else {
            return nil
        }
        if let data = property as? Data {
            let bytes = data.prefix { $0 != 0 }
            let value = String(decoding: bytes, as: UTF8.self)
            return value.isEmpty ? nil : value
        }
        if let value = property as? String {
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
