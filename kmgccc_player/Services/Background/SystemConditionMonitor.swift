import AppKit
import Darwin
import Foundation
import IOKit.ps
import Network
import Observation

/// Something about the system changed.
nonisolated enum SystemConditionEvent: Sendable {
    case powerSource
    case lowPowerMode
    case thermal
    case memoryPressure(SystemMemoryPressureLevel)
    case network
    case launchSettled
    /// A new sample of the load of everything but this App is available.
    case cpuSample
}

nonisolated struct SystemNetworkStatus: Equatable, Sendable {
    var isAvailable = true
    /// Personal hotspot or a similar metered path.
    var isExpensive = false
    /// Low Data Mode.
    var isConstrained = false

    nonisolated init(isAvailable: Bool = true, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isAvailable = isAvailable
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    nonisolated var isMetered: Bool { isExpensive || isConstrained }
}

/// The one observer of the machine's condition: power source, Low Power Mode,
/// thermal state, memory pressure, network path and the load of other
/// processes. The scheduler, the memory-pressure cache purge and the visual
/// degradation read this instead of watching the system on their own.
///
/// Everything is event driven except the CPU sample, which runs only while a
/// requester (idle work waiting) asks for it, and a slow tick that keeps the
/// session statistics honest.
@Observable
@MainActor
final class SystemConditionMonitor {
    private(set) var isOnACPower = true
    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var thermalLevel = SystemThermalLevel(ProcessInfo.processInfo.thermalState)
    private(set) var memoryPressure: SystemMemoryPressureLevel = .normal
    private(set) var network = SystemNetworkStatus()
    /// The first library is loaded and the first-use warm-up has finished.
    private(set) var isLaunchSettled = false
    /// Mean of the last ~30 s of CPU load excluding this App, in percent of
    /// all cores. Nil while no sampling runs.
    private(set) var otherCPULoadPercent: Double?
    /// Samples inside the current averaging window.
    private(set) var cpuWindowSampleCount = 0

    /// Uptime of the latest memory pressure event, if any.
    @ObservationIgnored private(set) var lastMemoryPressureEventUptime: TimeInterval?

    @ObservationIgnored private var observers: [UUID: @MainActor (SystemConditionEvent) -> Void] = [:]
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var memorySource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var samplingTimer: Timer?
    @ObservationIgnored private var settleFallbackTask: Task<Void, Never>?
    @ObservationIgnored private var cpuRequesters: Set<String> = []
    @ObservationIgnored private var cpuSamples: [(time: TimeInterval, otherPercent: Double)] = []
    @ObservationIgnored private var lastCPUReading: (busy: UInt64, total: UInt64, ownSeconds: Double)?
    @ObservationIgnored private let hostPort = mach_host_self()
    @ObservationIgnored private var started = false

    nonisolated static let samplingInterval: TimeInterval = 7
    nonisolated static let averagingWindow: TimeInterval = 30
    /// Without a signal, the launch counts as settled after this long.
    nonisolated static let launchSettleFallback: Duration = .seconds(180)

    /// The App's single monitor. The dependency owner starts it; views and
    /// skins read its state instead of watching power and heat themselves.
    static let shared = SystemConditionMonitor()

    init() {}

    /// Heavy visual effects step down: Low Power Mode, or the machine is hot.
    var prefersReducedVisualEffort: Bool {
        isLowPowerModeEnabled || thermalLevel >= .serious
    }

    // MARK: - Observation

    @discardableResult
    func addObserver(_ handler: @escaping @MainActor (SystemConditionEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) { observers[token] = nil }

    private func publish(_ event: SystemConditionEvent) {
        for handler in observers.values { handler(event) }
    }

    // MARK: - Lifecycle

    /// Starts the event sources. Called once by the App dependency owner.
    func start() {
        guard !started else { return }
        started = true
        refreshPowerSource()
        refreshMemoryPressure()
        installPowerSourceNotification()
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.publish(.lowPowerMode)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.thermalLevel = SystemThermalLevel(ProcessInfo.processInfo.thermalState)
                self.publish(.thermal)
            }
        })
        installMemoryPressureSource()
        installPathMonitor()
        settleFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.launchSettleFallback)
            guard !Task.isCancelled else { return }
            self?.markLaunchSettled()
        }
    }

    /// The first library is loaded and the first-use warm-up is done; idle
    /// work may start judging conditions.
    func markLaunchSettled() {
        guard !isLaunchSettled else { return }
        isLaunchSettled = true
        settleFallbackTask?.cancel()
        settleFallbackTask = nil
        publish(.launchSettled)
    }

    // MARK: - Memory pressure

    private func installMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            let level: SystemMemoryPressureLevel = event.contains(.critical)
                ? .critical : (event.contains(.warning) ? .warning : .normal)
            Task { @MainActor [weak self] in self?.handleMemoryPressure(level) }
        }
        source.resume()
        memorySource = source
    }

    private func handleMemoryPressure(_ level: SystemMemoryPressureLevel) {
        memoryPressure = level
        if level != .normal {
            lastMemoryPressureEventUptime = ProcessInfo.processInfo.systemUptime
        }
        publish(.memoryPressure(level))
    }

    // MARK: - Network

    private func installPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let status = SystemNetworkStatus(
                isAvailable: path.status == .satisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            Task { @MainActor [weak self] in
                guard let self, self.network != status else { return }
                self.network = status
                self.publish(.network)
            }
        }
        monitor.start(queue: DispatchQueue(label: "kmgccc.system-conditions.network", qos: .utility))
        pathMonitor = monitor
    }

    // MARK: - Power source

    private func installPowerSourceNotification() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SystemConditionMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                let previous = monitor.isOnACPower
                monitor.refreshPowerSource()
                if monitor.isOnACPower != previous { monitor.publish(.powerSource) }
            }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func refreshPowerSource() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            // A desktop Mac without a power source report runs on AC power.
            isOnACPower = true
            return
        }
        isOnACPower = (type as String) == kIOPMACPowerKey
    }

    // MARK: - CPU load excluding this process

    /// Starts or stops sampling for one requester. Sampling runs while any
    /// requester needs it and not otherwise.
    func setCPUSampling(_ enabled: Bool, requester: String) {
        if enabled { cpuRequesters.insert(requester) } else { cpuRequesters.remove(requester) }
        updateSamplingTimer()
    }

    private func updateSamplingTimer() {
        if !cpuRequesters.isEmpty, samplingTimer == nil {
            lastCPUReading = Self.cpuReading(host: hostPort)
            let timer = Timer(timeInterval: Self.samplingInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sampleCPU() }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            samplingTimer = timer
        } else if cpuRequesters.isEmpty, let timer = samplingTimer {
            timer.invalidate()
            samplingTimer = nil
            cpuSamples.removeAll()
            lastCPUReading = nil
            otherCPULoadPercent = nil
            cpuWindowSampleCount = 0
        }
    }

    private func sampleCPU() {
        guard let current = Self.cpuReading(host: hostPort) else { return }
        defer { lastCPUReading = current }
        guard let previous = lastCPUReading, current.total > previous.total else { return }
        let totalTicks = Double(current.total - previous.total)
        let busyFraction = Double(current.busy &- previous.busy) / totalTicks
        let ticksPerSecond = Double(max(1, sysconf(_SC_CLK_TCK)))
        let ownFraction = max(0, current.ownSeconds - previous.ownSeconds) * ticksPerSecond / totalTicks
        let other = max(0, min(100, (busyFraction - ownFraction) * 100))
        let now = ProcessInfo.processInfo.systemUptime
        cpuSamples.append((now, other))
        cpuSamples.removeAll { now - $0.time > Self.averagingWindow }
        otherCPULoadPercent = cpuSamples.map(\.otherPercent).reduce(0, +) / Double(cpuSamples.count)
        cpuWindowSampleCount = cpuSamples.count
        publish(.cpuSample)
    }

    private nonisolated static func cpuReading(host: mach_port_t) -> (busy: UInt64, total: UInt64, ownSeconds: Double)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let own = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return (user + system + nice, user + system + nice + idle, own)
    }

    // MARK: - Pressure level read

    /// Reads the system's current memory pressure level. A Mac that sits at
    /// "warning" all day is normal; only the level itself is recorded here, and
    /// the scheduler reacts to new events and to "critical".
    func refreshMemoryPressure() {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return }
        let level: SystemMemoryPressureLevel
        switch value {
        case 4: level = .critical
        case 2: level = .warning
        default: level = .normal
        }
        if memoryPressure != level { memoryPressure = level }
    }
}
