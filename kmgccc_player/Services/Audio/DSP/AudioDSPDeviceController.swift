import CoreAudio
import Foundation
import Observation

/// One output route as the DSP sees it: a Core Audio device, plus its data
/// source when the device switches between sources (built-in speakers and
/// the headphone jack on one device). Each route keeps its own preset.
nonisolated struct DSPOutputDeviceKey: Hashable, Sendable {
    var uid: String
    var dataSource: UInt32?

    var rawValue: String {
        guard let dataSource else { return uid }
        return uid + "#" + AudioOutputDataSource.code(dataSource)
    }
}

nonisolated struct DSPOutputDevice: Identifiable, Equatable, Sendable {
    var key: DSPOutputDeviceKey
    var deviceID: AudioDeviceID
    var name: String
    var transportType: UInt32

    var id: String { key.rawValue }
    var uid: String { key.uid }

    var symbolName: String {
        if let source = key.dataSource {
            switch AudioOutputDataSource.code(source) {
            case "hdpn": return "headphones"
            case "ispk": return "speaker.wave.2"
            default: break
            }
        }
        let identity = (name + " " + uid).lowercased()
        if identity.contains("airpods max") { return "airpodsmax" }
        if identity.contains("airpods pro") { return "airpodspro" }
        if identity.contains("airpods") { return "airpods" }
        if identity.contains("homepod mini") { return "homepodmini" }
        if identity.contains("homepod") { return "homepod" }
        if identity.contains("headphone") || identity.contains("headset")
            || identity.contains("耳机") || identity.contains("耳機") {
            return "headphones"
        }
        if transportType == kAudioDeviceTransportTypeHDMI
            || transportType == kAudioDeviceTransportTypeDisplayPort {
            return "display"
        }
        if transportType == kAudioDeviceTransportTypeBuiltIn { return "speaker.wave.2" }
        return "hifispeaker"
    }

    /// Headphones and earbuds, by the same identification as the symbol;
    /// everything else, displays included, plays through speakers.
    var outputKind: DSPOutputKind {
        switch symbolName {
        case "headphones", "airpods", "airpodspro", "airpodsmax": .headphones
        default: .speakers
        }
    }

    /// The route currently presented by a Core Audio device.
    static func resolve(_ descriptor: AudioOutputDeviceDescriptor) -> DSPOutputDevice {
        let source = AudioOutputDataSource.current(deviceID: descriptor.deviceID)
        let switchable = source?.isSwitchable == true
        var name = descriptor.name
        if switchable, let sourceName = source?.name, !sourceName.isEmpty, sourceName != name {
            name += " · " + sourceName
        }
        return DSPOutputDevice(
            key: DSPOutputDeviceKey(uid: descriptor.uniqueID, dataSource: switchable ? source?.id : nil),
            deviceID: descriptor.deviceID,
            name: name,
            transportType: descriptor.transportType
        )
    }
}

/// The preset a route plays through. A route without a profile plays flat.
nonisolated struct DSPDeviceProfile: Codable, Equatable, Sendable {
    var deviceKey: String
    var name: String
    var transportType: UInt32
    var presetID: UUID
}

/// Owner of the route-to-preset profiles. Every preset belongs to at most
/// one route; the current route remembers whatever preset it ends up on,
/// whether chosen by hand or created by editing the built-in flat preset.
@Observable
@MainActor
final class AudioDSPDeviceController {
    private(set) var profiles: [String: DSPDeviceProfile]
    /// Output routes available now.
    private(set) var devices: [DSPOutputDevice] = []
    /// The confirmed playback route.
    private(set) var currentDevice: DSPOutputDevice? {
        didSet {
            guard oldValue != currentDevice else { return }
            onCurrentOutputDeviceChange?(currentDevice)
        }
    }
    private(set) var isLoaded = false
    /// Shared with equal-loudness observation.
    @ObservationIgnored var onCurrentOutputDeviceChange: (@MainActor (DSPOutputDevice?) -> Void)?

    @ObservationIgnored private var routedDeviceUID: String?
    @ObservationIgnored private var refreshOutputRoute: (() -> Void)?
    @ObservationIgnored private var outputRouteOwnerID: ObjectIdentifier?
    @ObservationIgnored private let dsp: AudioDSPController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let deviceProvider: () -> [DSPOutputDevice]
    private static let storageKey = "audio.dsp-device-profiles.v2"
    @ObservationIgnored private var deviceObservation: AudioOutputDeviceObservation?
    @ObservationIgnored private var dataSourceObservation: AudioOutputDataSourceObservation?
    @ObservationIgnored private var observedDataSourceDeviceID: AudioDeviceID?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?

    init(
        dsp: AudioDSPController,
        userDefaults: UserDefaults = .standard,
        deviceProvider: @escaping () -> [DSPOutputDevice] = {
            AudioOutputLatencyMonitor.availableOutputDevices().map(DSPOutputDevice.resolve)
        }
    ) {
        self.dsp = dsp
        defaults = userDefaults
        self.deviceProvider = deviceProvider
        profiles = userDefaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: DSPDeviceProfile].self, from: $0) }
            ?? [:]
        dsp.onPresetDeleted = { [weak self] id in self?.presetWasDeleted(id) }
        dsp.onSelectedPresetChange = { [weak self] id in self?.recordSelection(id) }
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            await dsp.ensureLoaded()
            self.isLoaded = true
            self.removeMissingPresets()
            self.applyCurrentRule()
        }
    }

    func ensureLoaded() async { await bootstrapTask?.value }

    /// Started by the application dependency owner, never by a settings view.
    func start() {
        guard deviceObservation == nil else { return }
        deviceObservation = AudioOutputDeviceObservation { [weak self] in self?.refreshDevices() }
        refreshDevices()
    }

    func refreshDevices() {
        devices = deviceProvider()
        var changed = false
        for device in devices {
            guard var profile = profiles[device.id],
                  profile.name != device.name || profile.transportType != device.transportType else { continue }
            profile.name = device.name
            profile.transportType = device.transportType
            profiles[device.id] = profile
            changed = true
        }
        if changed { persist() }
        if let refreshOutputRoute {
            refreshOutputRoute()
        } else {
            // Before a library renderer is attached, use the selected available
            // route so startup rules also work in the settings-only state.
            routedDeviceUID = AudioOutputLatencyMonitor.currentSnapshot(
                forDeviceUID: AppSettings.shared.audioOutputDeviceUID
            ).deviceUID
        }
        // A data source switch keeps the device UID, so the route is resolved
        // again even when the renderer reports no change.
        resolveCurrentDevice()
    }

    func attachOutputRoute(owner: AnyObject, refresh: @escaping () -> Void) {
        outputRouteOwnerID = ObjectIdentifier(owner)
        refreshOutputRoute = refresh
    }

    func detachOutputRoute(owner: AnyObject) {
        guard outputRouteOwnerID == ObjectIdentifier(owner) else { return }
        outputRouteOwnerID = nil
        refreshOutputRoute = nil
    }

    func receiveOutputDeviceUID(_ uid: String?, ownerID: ObjectIdentifier? = nil) {
        guard outputRouteOwnerID == ownerID else { return }
        routedDeviceUID = uid
        resolveCurrentDevice()
    }

    /// The preset a route plays: its own, or flat.
    func presetID(for device: DSPOutputDevice) -> UUID {
        guard let id = profiles[device.id]?.presetID,
              dsp.presets.contains(where: { $0.presetID == id }) else { return DSPPresetDocument.flatPresetID }
        return id
    }

    /// The other route a preset belongs to. The built-in preset belongs to none.
    func presetOwner(_ id: UUID, excluding device: DSPOutputDevice?) -> DSPDeviceProfile? {
        guard id != DSPPresetDocument.flatPresetID else { return nil }
        return profiles.values.first { $0.presetID == id && $0.deviceKey != device?.id }
    }

    /// Selects a preset for the current route. A preset that belongs to
    /// another route is never shared: with `copyIfOwned` the route gets its
    /// own copy, without a calibration recorded elsewhere.
    func selectPresetForCurrentDevice(_ id: UUID, copyIfOwned: Bool = false) async throws {
        await ensureLoaded()
        guard let device = currentDevice else {
            throw DSPConfigurationValidationError(diagnostics: [DSPDiagnostic(
                code: "dsp.outputDeviceUnavailable", message: "未识别当前输出设备。", retryable: true
            )])
        }
        var target = id
        if let owner = presetOwner(id, excluding: device) {
            guard copyIfOwned else { throw occupiedPreset(owner.name) }
            let source = try await dsp.preset(id: id)
            target = try await dsp.duplicatePreset(
                id: id, name: "\(source.name) · \(device.name)", expectedPresetRevision: source.revisionString
            ).presetID
        }
        guard currentDevice?.id == device.id else { return }
        _ = try dsp.selectPreset(id: target)
        if target != id, dsp.configuration.equalLoudness.calibration != nil {
            dsp.updateConfiguration(recordsUndo: false) { $0.equalLoudness.calibration = nil }
        }
        dsp.commitPendingApply()
    }

    private func resolveCurrentDevice() {
        // The renderer can confirm a route before the device list catches up.
        if let uid = routedDeviceUID, !devices.contains(where: { $0.uid == uid }) {
            devices = deviceProvider()
        }
        let device = routedDeviceUID.flatMap { uid in devices.first { $0.uid == uid } }
        observeDataSource(of: device)
        guard device != currentDevice else { return }
        let routeChanged = device?.id != currentDevice?.id
        currentDevice = device
        if routeChanged { applyCurrentRule() }
    }

    private func observeDataSource(of device: DSPOutputDevice?) {
        guard device?.deviceID != observedDataSourceDeviceID else { return }
        observedDataSourceDeviceID = device?.deviceID
        dataSourceObservation = device.map { device in
            AudioOutputDataSourceObservation(deviceID: device.deviceID) { [weak self] in self?.refreshDevices() }
        }
    }

    private func applyCurrentRule() {
        guard isLoaded, let device = currentDevice else { return }
        let id = presetID(for: device)
        guard dsp.selectedPresetID != id else { return }
        do {
            _ = try dsp.selectPreset(id: id)
            dsp.commitPendingApply()
        } catch { dsp.report(error: error) }
    }

    /// Whatever the current route ends up playing is remembered for it.
    private func recordSelection(_ id: UUID?) {
        guard isLoaded, let device = currentDevice, let id else { return }
        var next = profiles
        if id == DSPPresetDocument.flatPresetID {
            next[device.id] = nil
        } else {
            next = next.filter { $0.value.presetID != id || $0.key == device.id }
            next[device.id] = DSPDeviceProfile(
                deviceKey: device.id, name: device.name, transportType: device.transportType, presetID: id
            )
        }
        guard next != profiles else { return }
        profiles = next
        persist()
    }

    private func presetWasDeleted(_ id: UUID) {
        let affectsCurrent = currentDevice.flatMap { profiles[$0.id]?.presetID } == id
        profiles = profiles.filter { $0.value.presetID != id }
        persist()
        if affectsCurrent { applyCurrentRule() }
    }

    private func removeMissingPresets() {
        let ids = Set(dsp.presets.map(\.presetID))
        let kept = profiles.filter { ids.contains($0.value.presetID) }
        guard kept != profiles else { return }
        profiles = kept
        persist()
    }

    private func persist() {
        do { defaults.set(try JSONEncoder().encode(profiles), forKey: Self.storageKey) }
        catch { dsp.report(error: error) }
    }

    private func occupiedPreset(_ owner: String) -> DSPConfigurationValidationError {
        DSPConfigurationValidationError(diagnostics: [DSPDiagnostic(
            code: "dsp.presetAlreadyBound", message: "此音效已用于\(owner)。"
        )])
    }
}
