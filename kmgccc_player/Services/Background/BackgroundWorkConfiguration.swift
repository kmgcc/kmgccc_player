import Foundation

/// How hard idle batch work may push. Gentle rests between units; the other
/// finishes sooner at the cost of power and heat.
nonisolated enum BackgroundPacingMode: String, CaseIterable, Sendable {
    case gentle
    case fast
}

/// The listener's choices for background preparation.
nonisolated struct BackgroundWorkConfiguration: Equatable, Sendable {
    /// Master switch for idle batch work and preloading. Work the listener
    /// asks for, and measurement volume normalization needs, is unaffected.
    var preparationEnabled = true
    var pacing: BackgroundPacingMode = .gentle
    /// Domains the listener switched off one by one.
    var disabledDomains: Set<BackgroundWorkDomain> = []

    nonisolated func allows(_ domain: BackgroundWorkDomain) -> Bool {
        !disabledDomains.contains(domain)
    }
}

/// Initial pacing parameters by machine class. They are estimates from the
/// installed base (fanless laptops dominate) and are tuned later from the
/// anonymous scheduling statistics.
nonisolated struct BackgroundDeviceProfile: Equatable, Sendable {
    nonisolated enum MachineClass: String, Sendable {
        case fanlessLaptop = "fanless_laptop"
        case fannedLaptop = "fanned_laptop"
        case desktop
        case unknown
    }

    nonisolated let machineClass: MachineClass
    nonisolated let isSmallMemory: Bool

    /// Memory at or below this many GB counts as small.
    nonisolated static let smallMemoryGB = 8

    nonisolated init(machineClass: MachineClass, isSmallMemory: Bool) {
        self.machineClass = machineClass
        self.isSmallMemory = isSmallMemory
    }

    nonisolated init(deviceFamily: String, memoryGB: Int?) {
        let machineClass: MachineClass
        switch deviceFamily {
        case "MacBook Air", "MacBook Neo", "MacBook":
            machineClass = .fanlessLaptop
        case "MacBook Pro":
            machineClass = .fannedLaptop
        case "Mac mini", "Mac Studio", "iMac", "Mac Pro":
            machineClass = .desktop
        default:
            machineClass = .unknown
        }
        self.init(
            machineClass: machineClass,
            isSmallMemory: memoryGB.map { $0 <= Self.smallMemoryGB } ?? false
        )
    }

    /// Rest after an idle unit, as a multiple of the time it ran. Gentle
    /// pacing keeps the background load near half an efficiency core.
    nonisolated var gentleRestFactor: Double {
        let base: Double
        switch machineClass {
        case .fanlessLaptop, .unknown: base = 2
        case .fannedLaptop: base = 1
        case .desktop: base = 0.5
        }
        return isSmallMemory ? max(base, 2) : base
    }

    /// Whether component-specific next-song preparation is allowed. Small
    /// memory and unrecognized machines only prepare shared assets.
    nonisolated var allowsComponentPreparation: Bool {
        !isSmallMemory && machineClass != .unknown
    }

    /// Rest multiple for the next unit under the current choices.
    /// `thermalFairOrWorse` lengthens the rest to three times and takes
    /// "fast" back to the gentle pace.
    nonisolated func restFactor(mode: BackgroundPacingMode, thermalFairOrWorse: Bool) -> Double {
        if thermalFairOrWorse { return max(3, gentleRestFactor) }
        switch mode {
        case .gentle: return gentleRestFactor
        case .fast: return 0
        }
    }

    @MainActor
    static func current() -> BackgroundDeviceProfile {
        let snapshot = DeviceTelemetryProvider.current()
        return BackgroundDeviceProfile(deviceFamily: snapshot.deviceFamily, memoryGB: snapshot.memoryGB)
    }
}
