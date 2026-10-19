import Foundation
import Observation

/// Owner of the App-wide transport fade and volume normalization settings.
/// Equal-loudness compensation lives entirely in the DSP equal-loudness node,
/// driven by the routed device's system volume.
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
    }

    func receiveAudioProcessingRuntimeState(_ state: AudioProcessingRuntimeState) {
        publishRuntimeState(state)
    }

    func clearErrors() {
        lastError = nil
    }

    func report(error: Error) {
        record(error)
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

        if !AudioLoudnessConfiguration.targetRange.contains(configuration.loudness.targetLUFS)
            || !configuration.loudness.targetLUFS.isFinite {
            add("目标响度范围为 −20 至 −8 LUFS。", "loudness.targetLUFS")
        }
        return diagnostics
    }
}
