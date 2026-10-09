import Foundation
import Observation

@Observable
@MainActor
final class AudioProcessingGlobalsController {
    private(set) var configuration: AudioProcessingGlobals
    private(set) var revisionString: String
    private(set) var lastError: DSPDiagnostic?
    private(set) var runtimeState = AudioProcessingRuntimeState()

    var applyConfiguration: (@MainActor (AudioProcessingGlobals, String, UUID) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private var sourceIsLocal = true

    static let defaultStorageKey = "audio.processing-globals.v1"

    var equalLoudnessContext: DSPEqualLoudnessContext {
        DSPEqualLoudnessContext(
            appGain: runtimeState.appGain,
            deviceUID: runtimeState.outputDeviceUID,
            referenceDB: runtimeState.referenceDB
        )
    }

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "audio.processing-globals.v1"
    ) {
        defaults = userDefaults
        self.storageKey = storageKey
        revisionString = UUID().uuidString

        if let data = userDefaults.data(forKey: storageKey) {
            do {
                let loaded = try JSONDecoder().decode(AudioProcessingGlobals.self, from: data)
                let issues = Self.validationDiagnostics(for: loaded)
                if issues.isEmpty {
                    configuration = loaded
                } else {
                    configuration = AudioProcessingGlobals()
                    lastError = issues.first
                }
            } catch {
                configuration = AudioProcessingGlobals()
                lastError = DSPDiagnostic(
                    code: "audio.globalsStoreInvalid",
                    message: "全局音频设置无法读取，已使用默认值。",
                    fieldPath: "audioProcessingGlobals"
                )
            }
        } else {
            configuration = AudioProcessingGlobals()
        }
    }

    @discardableResult
    func validate(_ candidate: AudioProcessingGlobals) throws -> AudioProcessingGlobals {
        let issues = Self.validationDiagnostics(for: candidate)
        guard issues.isEmpty else {
            throw DSPConfigurationValidationError(diagnostics: issues)
        }
        return candidate
    }

    @discardableResult
    func apply(
        _ candidate: AudioProcessingGlobals,
        expectedRevision: String? = nil,
        dryRun: Bool = false
    ) throws -> String {
        if let expectedRevision, expectedRevision != revisionString {
            throw DSPConfigurationValidationError(diagnostics: [DSPDiagnostic(
                code: "dsp.revisionConflict",
                message: "全局音频设置已更新，请重新载入后再试。",
                fieldPath: "expectedRevision",
                retryable: true
            )])
        }

        let validated = try validate(candidate)
        guard !dryRun else { return revisionString }

        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoded = try encoder.encode(validated)
        } catch {
            let diagnostic = DSPDiagnostic(
                code: "audio.globalsStoreWriteFailed",
                message: "全局音频设置无法保存。",
                fieldPath: "audioProcessingGlobals",
                retryable: true
            )
            lastError = diagnostic
            throw DSPConfigurationValidationError(diagnostics: [diagnostic])
        }

        defaults.set(encoded, forKey: storageKey)
        configuration = validated
        revisionString = UUID().uuidString
        lastError = nil
        refreshReferenceInRuntimeState()
        if sourceIsLocal {
            applyConfiguration?(validated, revisionString, UUID())
        }
        return revisionString
    }

    func updateConfiguration(
        _ update: (inout AudioProcessingGlobals) -> Void
    ) {
        var candidate = configuration
        update(&candidate)
        do {
            _ = try apply(candidate)
        } catch {
            record(error)
        }
    }

    func bindPlayback(
        apply handler: @escaping @MainActor (AudioProcessingGlobals, String, UUID) -> Void
    ) {
        applyConfiguration = handler
        guard sourceIsLocal else { return }
        handler(configuration, revisionString, UUID())
    }

    func setSourceIsLocal(_ isLocal: Bool) {
        guard sourceIsLocal != isLocal else { return }
        sourceIsLocal = isLocal
        if !isLocal {
            runtimeState = AudioProcessingRuntimeState()
        } else if let applyConfiguration {
            applyConfiguration(configuration, revisionString, UUID())
        }
    }

    func detachPlayback() {
        applyConfiguration = nil
        sourceIsLocal = false
        runtimeState = AudioProcessingRuntimeState()
    }

    func publishRuntimeState(_ state: AudioProcessingRuntimeState) {
        guard sourceIsLocal else { return }
        runtimeState = state
        refreshReferenceInRuntimeState()
    }

    func receiveAudioProcessingRuntimeState(_ state: AudioProcessingRuntimeState) {
        publishRuntimeState(state)
    }

    func deviceReference(for deviceUID: String) -> Double? {
        configuration.deviceReferences[deviceUID]
    }

    @discardableResult
    func setDeviceReference(
        _ referenceDB: Double?,
        for deviceUID: String,
        expectedRevision: String? = nil,
        dryRun: Bool = false
    ) throws -> String {
        var candidate = configuration
        if let referenceDB {
            candidate.deviceReferences[deviceUID] = referenceDB
        } else {
            candidate.deviceReferences.removeValue(forKey: deviceUID)
        }
        return try apply(candidate, expectedRevision: expectedRevision, dryRun: dryRun)
    }

    @discardableResult
    func useCurrentVolumeAsReference(
        expectedRevision: String? = nil,
        dryRun: Bool = false
    ) throws -> String {
        guard let deviceUID = runtimeState.outputDeviceUID,
              !deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              runtimeState.appGain.isFinite,
              runtimeState.appGain > 0 else {
            let diagnostic = DSPDiagnostic(
                code: "audio.referenceUnavailable",
                message: "当前输出设备或音量不可用于设置参考。",
                fieldPath: "deviceReferences",
                retryable: true
            )
            lastError = diagnostic
            throw DSPConfigurationValidationError(diagnostics: [diagnostic])
        }
        let referenceDB = max(-100, 20 * log10(min(1, runtimeState.appGain)))
        return try setDeviceReference(
            referenceDB,
            for: deviceUID,
            expectedRevision: expectedRevision,
            dryRun: dryRun
        )
    }

    func clearErrors() {
        lastError = nil
    }

    func report(error: Error) {
        record(error)
    }

    private func refreshReferenceInRuntimeState() {
        guard let deviceUID = runtimeState.outputDeviceUID else {
            runtimeState.referenceDB = nil
            return
        }
        runtimeState.referenceDB = configuration.deviceReferences[deviceUID]
    }

    private func record(_ error: Error) {
        if let validationError = error as? DSPConfigurationValidationError {
            lastError = validationError.diagnostics.first
        } else {
            lastError = DSPDiagnostic(
                code: "audio.globalsApplyFailed",
                message: error.localizedDescription,
                fieldPath: "audioProcessingGlobals",
                retryable: true
            )
        }
    }

    private static func validationDiagnostics(
        for configuration: AudioProcessingGlobals
    ) -> [DSPDiagnostic] {
        var diagnostics = [DSPDiagnostic]()
        func add(_ message: String, _ path: String) {
            diagnostics.append(DSPDiagnostic(
                code: "dsp.invalidParameter",
                message: message,
                fieldPath: path
            ))
        }

        if !(10...2_000).contains(configuration.fade.playFadeMs) || !configuration.fade.playFadeMs.isFinite {
            add("播放淡入时长范围为 10 至 2,000 ms。", "fade.playFadeMs")
        }
        if !(10...2_000).contains(configuration.fade.pauseFadeMs) || !configuration.fade.pauseFadeMs.isFinite {
            add("暂停淡出时长范围为 10 至 2,000 ms。", "fade.pauseFadeMs")
        }
        if !(-100 ... -40).contains(configuration.fade.floorDB) || !configuration.fade.floorDB.isFinite {
            add("淡化底值范围为 −100 至 −40 dB。", "fade.floorDB")
        }
        if configuration.fade.curve != "perceptualDB" {
            add("当前只支持 perceptualDB 淡化曲线。", "fade.curve")
        }

        if !["auto", "track", "album"].contains(configuration.loudness.mode) {
            add("响度模式必须为 auto、track 或 album。", "loudness.mode")
        }
        if !(-30 ... -10).contains(configuration.loudness.targetLUFS)
            || !configuration.loudness.targetLUFS.isFinite {
            add("响度目标范围为 −30 至 −10 LUFS。", "loudness.targetLUFS")
        }
        if !(0...24).contains(configuration.loudness.maxBoostDB)
            || !configuration.loudness.maxBoostDB.isFinite {
            add("最大提升范围为 0 至 24 dB。", "loudness.maxBoostDB")
        }
        if !(0...60).contains(configuration.loudness.maxAttenuationDB)
            || !configuration.loudness.maxAttenuationDB.isFinite {
            add("最大衰减范围为 0 至 60 dB。", "loudness.maxAttenuationDB")
        }
        if !(-12...0).contains(configuration.loudness.truePeakCeilingDBTP)
            || !configuration.loudness.truePeakCeilingDBTP.isFinite {
            add("真实峰值上限范围为 −12 至 0 dBTP。", "loudness.truePeakCeilingDBTP")
        }
        if configuration.loudness.missingPolicy != "unity" {
            add("缺少响度数据时当前只支持保持原音量。", "loudness.missingPolicy")
        }

        for (deviceUID, referenceDB) in configuration.deviceReferences {
            if deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("输出设备标识不能为空。", "deviceReferences")
            }
            if !(-100...0).contains(referenceDB) || !referenceDB.isFinite {
                add("设备参考音量范围为 −100 至 0 dB。", "deviceReferences.\(deviceUID)")
            }
        }
        return diagnostics
    }
}
