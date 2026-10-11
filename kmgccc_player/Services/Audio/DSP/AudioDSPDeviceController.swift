import CoreAudio
import Foundation
import Observation

nonisolated struct DSPDeviceBinding: Codable, Equatable, Sendable, Identifiable {
    var deviceUID: String
    var name: String
    var transportType: UInt32
    var presetID: UUID

    var id: String { deviceUID }
}

nonisolated struct DSPDeviceSettings: Codable, Equatable, Sendable {
    var enabled = false
    var defaultPresetID: UUID?
    var bindings: [String: DSPDeviceBinding] = [:]
}

nonisolated struct DSPOutputDevice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var transportType: UInt32
    var isConnected: Bool

    var symbolName: String {
        let identity = (name + " " + id).lowercased()
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
        if transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE { return "hifispeaker" }
        return "hifispeaker"
    }
}

/// Stores device rules separately from the editable DSP presets. Manual preset
/// selection never changes a rule, and repeated route reports never undo it.
@Observable
@MainActor
final class AudioDSPDeviceController {
    private(set) var settings: DSPDeviceSettings
    private(set) var availableDevices: [AudioOutputDeviceDescriptor] = []
    private(set) var currentOutputDeviceUID: String?
    private(set) var isLoaded = false

    @ObservationIgnored private var refreshOutputRoute: (() -> Void)?
    @ObservationIgnored private var outputRouteOwnerID: ObjectIdentifier?
    @ObservationIgnored private let dsp: AudioDSPController
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "audio.dsp-device-bindings.v1"
    @ObservationIgnored private var deviceObservation: AudioOutputDeviceObservation?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?

    init(dsp: AudioDSPController, userDefaults: UserDefaults = .standard) {
        self.dsp = dsp
        defaults = userDefaults
        settings = userDefaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(DSPDeviceSettings.self, from: $0) }
            ?? DSPDeviceSettings()
        dsp.onPresetDeleted = { [weak self] id in self?.presetWasDeleted(id) }
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
        availableDevices = AudioOutputLatencyMonitor.availableOutputDevices()
        if let uid = currentOutputDeviceUID, !availableDevices.contains(where: { $0.uniqueID == uid }) {
            currentOutputDeviceUID = nil
        }
        var changed = false
        for device in availableDevices {
            guard var binding = settings.bindings[device.uniqueID] else { continue }
            if binding.name != device.name || binding.transportType != device.transportType {
                binding.name = device.name
                binding.transportType = device.transportType
                settings.bindings[device.uniqueID] = binding
                changed = true
            }
        }
        if changed { persist() }
        if let refreshOutputRoute {
            refreshOutputRoute()
        } else {
            // Before a library renderer is attached, use the selected available
            // route so startup rules also work in the settings-only state.
            receiveOutputDeviceUID(AudioOutputLatencyMonitor.currentSnapshot(
                forDeviceUID: AppSettings.shared.audioOutputDeviceUID
            ).deviceUID)
        }
    }

    var devices: [DSPOutputDevice] {
        var rows = availableDevices.map {
            DSPOutputDevice(id: $0.uniqueID, name: $0.name, transportType: $0.transportType, isConnected: true)
        }
        let connected = Set(rows.map(\.id))
        rows += settings.bindings.values.filter { !connected.contains($0.deviceUID) }.map {
            DSPOutputDevice(id: $0.deviceUID, name: $0.name, transportType: $0.transportType, isConnected: false)
        }
        return rows.sorted {
            if ($0.id == currentOutputDeviceUID) != ($1.id == currentOutputDeviceUID) {
                return $0.id == currentOutputDeviceUID
            }
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
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
        guard currentOutputDeviceUID != uid else { return }
        currentOutputDeviceUID = uid
        applyCurrentRule()
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.enabled != enabled else { return }
        settings.enabled = enabled
        persist()
        if enabled { applyCurrentRule() }
    }

    /// Returns the exclusive owner, including the reserved global default.
    func presetOwner(_ id: UUID, excluding deviceUID: String? = nil) -> String? {
        if settings.defaultPresetID == id { return "全局默认" }
        return settings.bindings.values.first {
            $0.presetID == id && $0.deviceUID != deviceUID
        }?.name
    }

    func bindPreset(_ id: UUID?, to device: DSPOutputDevice) async throws {
        await ensureLoaded()
        if let id, let owner = presetOwner(id, excluding: device.id) { throw occupiedPreset(owner) }
        let presetID = try await editablePresetID(id, name: "平直 · \(device.name)")
        if let presetID, let owner = presetOwner(presetID, excluding: device.id) { throw occupiedPreset(owner) }
        if let presetID {
            settings.bindings[device.id] = DSPDeviceBinding(
                deviceUID: device.id, name: device.name, transportType: device.transportType, presetID: presetID
            )
            settings.enabled = true
        } else {
            settings.bindings[device.id] = nil
        }
        persist()
        if currentOutputDeviceUID == device.id { applyCurrentRule() }
    }

    func setDefaultPreset(_ id: UUID?) async throws {
        await ensureLoaded()
        if let id, settings.defaultPresetID != id, let owner = presetOwner(id) { throw occupiedPreset(owner) }
        let presetID = try await editablePresetID(id, name: "默认音效")
        if let presetID, settings.defaultPresetID != presetID, let owner = presetOwner(presetID) {
            throw occupiedPreset(owner)
        }
        settings.defaultPresetID = presetID
        settings.enabled = true
        persist()
        if let uid = currentOutputDeviceUID, settings.bindings[uid] == nil { applyCurrentRule() }
    }

    private func editablePresetID(_ id: UUID?, name: String) async throws -> UUID? {
        guard let id else { return nil }
        let preset = try await dsp.preset(id: id)
        guard preset.isBuiltIn else { return id }
        // The built-in flat preset is immutable. Give a rule its own editable
        // copy so later parameter edits keep the same bound identity.
        return try await dsp.duplicatePreset(id: id, name: name).presetID
    }

    private func applyCurrentRule() {
        guard isLoaded, settings.enabled, let uid = currentOutputDeviceUID else { return }
        let bound = settings.bindings[uid]?.presetID
        let id = bound.flatMap { candidate in dsp.presets.contains { $0.presetID == candidate } ? candidate : nil }
            ?? settings.defaultPresetID
        do {
            if let id {
                _ = try dsp.selectPreset(id: id, enableDSP: true)
                dsp.commitPendingApply()
            } else {
                dsp.disableForOutputDevice()
            }
        } catch { dsp.report(error: error) }
    }

    private func presetWasDeleted(_ id: UUID) {
        let affectsCurrent = currentOutputDeviceUID.flatMap { settings.bindings[$0]?.presetID } == id
            || (settings.defaultPresetID == id && currentOutputDeviceUID.flatMap { settings.bindings[$0] } == nil)
        settings.bindings = settings.bindings.filter { $0.value.presetID != id }
        if settings.defaultPresetID == id { settings.defaultPresetID = nil }
        persist()
        if affectsCurrent { applyCurrentRule() }
    }

    private func removeMissingPresets() {
        let ids = Set(dsp.presets.map(\.presetID))
        settings.bindings = settings.bindings.filter { ids.contains($0.value.presetID) }
        if let id = settings.defaultPresetID, !ids.contains(id) { settings.defaultPresetID = nil }
        persist()
    }

    private func persist() {
        do { defaults.set(try JSONEncoder().encode(settings), forKey: Self.storageKey) }
        catch { dsp.report(error: error) }
    }

    private func occupiedPreset(_ owner: String) -> DSPConfigurationValidationError {
        DSPConfigurationValidationError(diagnostics: [DSPDiagnostic(
            code: "dsp.presetAlreadyBound", message: "此预设已用于\(owner)。"
        )])
    }
}
