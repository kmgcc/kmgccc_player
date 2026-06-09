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
struct DeviceTelemetrySnapshot: Equatable {
    let deviceFamily: String
    let chipFamily: String
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
        let isAppleSilicon = sysctlFlag("hw.optional.arm64")
        let marketingName = ioRegistryProductName()

        let family = DeviceTelemetryClassifier.deviceFamily(
            fromCandidates: [marketingName, modelIdentifier]
        )
        let chipFamily = DeviceTelemetryClassifier.chipFamily(
            isAppleSilicon: isAppleSilicon,
            brandString: brandString
        )
        let chipTier = DeviceTelemetryClassifier.chipTier(
            family: chipFamily,
            brandString: brandString
        )
        let memoryGB = DeviceTelemetryClassifier.memoryGB(
            fromBytes: ProcessInfo.processInfo.physicalMemory
        )
        let osMajor = DeviceTelemetryClassifier.osMajor(
            fromMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )

        return DeviceTelemetrySnapshot(
            deviceFamily: family,
            chipFamily: chipFamily,
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
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    private static func sysctlFlag(_ name: String) -> Bool? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value != 0
    }

    /// On Apple Silicon the device tree exposes a coarse marketing family at
    /// `IODeviceTree:/product` → `product-name` (NUL-terminated UTF-8 in CFData).
    /// Returns `nil` when unavailable so the caller falls back to `hw.model`.
    private static func ioRegistryProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        guard let property = IORegistryEntryCreateCFProperty(
            entry, "product-name" as CFString, kCFAllocatorDefault, 0
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
