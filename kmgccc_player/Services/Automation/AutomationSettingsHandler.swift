import AppKit
import CryptoKit
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

@MainActor
struct AutomationSettingsHandler {
    private weak var appSession: AppSessionHost?
    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }

    init(appSession: AppSessionHost?) {
        self.appSession = appSession
    }

    func handle(
        _ request: AutomationRequest
    ) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.settingsGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let settings = try await appSession.libraryScopedSettings()
                let values = automationSettingsValues(settings)
                return AutomationResponseSupport.encodeResult(
                    AutomationSettingsResult(
                        libraryID: session.context.id,
                        values: values,
                        revision: automationSettingsRevision(values),
                        message: "Only persistent settings with an App-owned automation contract are returned."
                    ),
                    for: request
                )
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to read automation settings.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.settingsPatch:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let requestedValues = try parameters.object("values") ?? [:]
                guard !requestedValues.isEmpty else {
                    throw AutomationParameterError.invalidValue("values")
                }
                let normalized = normalizeAutomationSettings(
                    requestedValues,
                    referencedLibrary: session.context.mode == .referenced
                )
                guard normalized.issues.isEmpty else {
                    throw AutomationParameterError.invalidValue(normalized.issues[0])
                }
                let current = try await appSession.libraryScopedSettings()
                let currentValues = automationSettingsValues(current)
                let currentRevision = automationSettingsRevision(currentValues)
                if let expectedRevision = try parameters.string("expectedRevision"),
                   expectedRevision != currentRevision {
                    return settingsRevisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: currentRevision
                    )
                }
                let requestedPolicy = normalized.values["referencedTrackDeletePolicy"]
                    .flatMap { value -> ReferencedTrackDeletePolicy? in
                        guard case .string(let rawValue) = value else { return nil }
                        return ReferencedTrackDeletePolicy(rawValue: rawValue)
                    }
                var nextValues = currentValues
                for (key, value) in normalized.values { nextValues[key] = value }
                let dryRun = try parameters.boolean("dryRun", default: false)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSettingsResult(
                            libraryID: session.context.id,
                            values: nextValues,
                            revision: automationSettingsRevision(nextValues),
                            applied: false,
                            dryRun: true,
                            message: "Preview only. No persistent setting was changed."
                        ),
                        for: request
                    )
                }
                if requestedPolicy == .recycleSource,
                   requestedPolicy != current.referencedTrackDeletePolicy {
                    let confirm = try parameters.boolean("confirm", default: false)
                    guard confirm else {
                        return AutomationResponseSupport.confirmationRequired(
                            for: request,
                            message: "启用“同时处理原文件”会改变以后删除引用歌曲的方式，需要播放器确认。",
                            details: .object([
                                "setting": .string("referencedTrackDeletePolicy"),
                                "value": .string(ReferencedTrackDeletePolicy.recycleSource.rawValue)
                            ])
                        )
                    }
                    guard await AutomationInteraction.confirmDestructiveOperation(
                        title: "更改引用歌曲的删除方式？",
                        message: "以后删除引用歌曲时，来源文件可能会移到废纸篓。"
                    ) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                }
                if let requestedPolicy {
                    try await appSession.setReferencedTrackDeletePolicy(
                        requestedPolicy,
                        libraryID: session.context.id
                    )
                }
                applyGlobalAutomationSettings(normalized.values)
                return AutomationResponseSupport.encodeResult(
                    AutomationSettingsResult(
                        libraryID: session.context.id,
                        values: nextValues,
                        revision: automationSettingsRevision(nextValues),
                        applied: true,
                        message: "Persistent automation settings updated by the App."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.settingsSchema:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard AutomationResponseSupport.isEmptyParameters(request.params) else { return AutomationResponseSupport.invalidParameters(for: request) }
            return AutomationResponseSupport.encodeResult(AutomationJSONValue.object([
                "libraryID": .string(session.context.id.uuidString),
                "settings": .object([
                    "referencedTrackDeletePolicy": .object([
                        "type": .string("string"),
                        "allowedValues": .array([
                            .string(ReferencedTrackDeletePolicy.onlyLibrary.rawValue),
                            .string(ReferencedTrackDeletePolicy.recycleSource.rawValue)
                        ]),
                        "default": .string(ReferencedTrackDeletePolicy.onlyLibrary.rawValue),
                        "appliesTo": .string("referenced library"),
                        "risk": .string("recycleSource may move original files to Trash when tracks are deleted")
                    ]),
                    "deferImportEnrichment": .object([
                        "type": .string("boolean"),
                        "default": .boolean(true),
                        "appliesTo": .string("app"),
                        "description": .string("When true, imported Tracks become visible while enrichment continues in the background.")
                    ]),
                    "globalArtworkTintEnabled": .object([
                        "type": .string("boolean"),
                        "default": .boolean(true),
                        "appliesTo": .string("app")
                    ]),
                    "audioVisualizationHDREnabled": .object([
                        "type": .string("boolean"),
                        "default": .boolean(true),
                        "appliesTo": .string("app")
                    ]),
                    "dockProgressVisible": .object([
                        "type": .string("boolean"),
                        "default": .boolean(true),
                        "appliesTo": .string("app")
                    ]),
                    "appearanceMode": .object([
                        "type": .string("string"),
                        "allowedValues": .array([.string("system"), .string("light"), .string("dark")]),
                        "default": .string("system"),
                        "appliesTo": .string("app")
                    ])
                ])
            ]), for: request)

        case AutomationMethod.settingsValidate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(for: request, error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true))
            }
            do {
                let parameters = try AutomationParameters(request)
                let requested = try parameters.object("values") ?? [:]
                let validation = normalizeAutomationSettings(
                    requested,
                    referencedLibrary: session.context.mode == .referenced
                )
                let current = try await appSession.libraryScopedSettings()
                let currentValues = automationSettingsValues(current)
                return AutomationResponseSupport.encodeResult(AutomationJSONValue.object([
                    "valid": .boolean(validation.issues.isEmpty),
                    "libraryID": .string(session.context.id.uuidString),
                    "currentRevision": .string(automationSettingsRevision(currentValues)),
                    "normalizedValues": .object(validation.values),
                    "issues": .array(validation.issues.map(AutomationJSONValue.string))
                ]), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.settingsReset:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(for: request, error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true))
            }
            do {
                let parameters = try AutomationParameters(request)
                let current = try await appSession.libraryScopedSettings()
                let currentValues = automationSettingsValues(current)
                let currentRevision = automationSettingsRevision(currentValues)
                if let expected = try parameters.string("expectedRevision"), expected != currentRevision {
                    return settingsRevisionConflict(for: request, expected: expected, actual: currentRevision)
                }
                var nextValues = defaultAutomationGlobalSettings
                if session.context.mode == .referenced {
                    nextValues["referencedTrackDeletePolicy"] = .string(ReferencedTrackDeletePolicy.onlyLibrary.rawValue)
                } else {
                    nextValues["referencedTrackDeletePolicy"] = currentValues["referencedTrackDeletePolicy"]
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                if !dryRun {
                    if session.context.mode == .referenced {
                        try await appSession.setReferencedTrackDeletePolicy(.onlyLibrary, libraryID: session.context.id)
                    }
                    applyGlobalAutomationSettings(defaultAutomationGlobalSettings)
                }
                return AutomationResponseSupport.encodeResult(AutomationSettingsResult(
                    libraryID: session.context.id,
                    values: nextValues,
                    revision: automationSettingsRevision(nextValues),
                    applied: !dryRun,
                    dryRun: dryRun,
                    message: dryRun ? "Preview only. No persistent setting was changed." : "Supported settings were reset to their documented defaults."
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.audioGet:
            guard AutomationResponseSupport.isEmptyParameters(request.params) else { return AutomationResponseSupport.invalidParameters(for: request) }
            guard let appSession else {
                return .failure(for: request, error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true))
            }
            let audio = appSession.automationAudioSettings()
            let output = AudioOutputLatencyMonitor.currentSnapshot()
            let activeOutput = AudioOutputLatencyMonitor.currentSnapshot(
                forDeviceUID: audio.outputDeviceUID
            )
            let outputDevices = AudioOutputLatencyMonitor.availableOutputDevices().map { device in
                AutomationJSONValue.object([
                    "id": .string(device.id),
                    "name": .string(device.name),
                    "sampleRateHz": .number(device.sampleRate),
                    "isBluetooth": .boolean(device.isBluetooth),
                    "isSystemDefault": .boolean(device.isDefault)
                ])
            }
            let values: [String: AutomationJSONValue] = [
                "gaplessSchedulingEnabled": .boolean(audio.gaplessSchedulingEnabled),
                "aacGaplessTrimEnabled": .boolean(audio.aacGaplessTrimEnabled),
                "outputDeviceID": audio.outputDeviceUID.map {
                    AutomationJSONValue.string(AudioOutputLatencyMonitor.stableDeviceID(for: $0))
                } ?? .null,
                "availableOutputDevices": .array(outputDevices),
                "currentSystemOutput": .object([
                    "available": .boolean(output.sampleRate > 0),
                    "name": .string(output.deviceName),
                    "sampleRateHz": .number(output.sampleRate),
                    "reportedLatencySeconds": .number(output.seconds),
                    "isBluetooth": .boolean(output.isBluetooth)
                ]),
                "activeOutput": .object([
                    "available": .boolean(activeOutput.sampleRate > 0),
                    "id": activeOutput.deviceUID.map {
                        AutomationJSONValue.string(AudioOutputLatencyMonitor.stableDeviceID(for: $0))
                    } ?? .null,
                    "name": .string(activeOutput.deviceName),
                    "sampleRateHz": .number(activeOutput.sampleRate),
                    "reportedLatencySeconds": .number(activeOutput.seconds),
                    "isBluetooth": .boolean(activeOutput.isBluetooth)
                ])
            ]
            return AutomationResponseSupport.encodeResult(AutomationSettingsResult(
                libraryID: sessionAccess.activeSession(for: request)?.context.id,
                values: values,
                revision: automationAudioRevision(
                    audio.gaplessSchedulingEnabled,
                    audio.aacGaplessTrimEnabled,
                    audio.outputDeviceUID
                ),
                message: "Persistent audio scheduling and preferred output settings, available output devices, and current route telemetry. Device availability may change independently of the settings revision."
            ), for: request)

        case AutomationMethod.audioPatch:
            guard let appSession else {
                return .failure(for: request, error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true))
            }
            do {
                let parameters = try AutomationParameters(request)
                let requested = try parameters.object("values") ?? [:]
                guard !requested.isEmpty,
                      Set(requested.keys).isSubset(of: ["gaplessSchedulingEnabled", "aacGaplessTrimEnabled", "outputDeviceID"]) else {
                    throw AutomationParameterError.invalidValue("values")
                }
                func boolValue(_ key: String) throws -> Bool? {
                    guard let value = requested[key] else { return nil }
                    guard case .boolean(let enabled) = value else { throw AutomationParameterError.invalidValue("values.\(key)") }
                    return enabled
                }
                let gapless = try boolValue("gaplessSchedulingEnabled")
                let aacTrim = try boolValue("aacGaplessTrimEnabled")
                let requestedOutputDeviceUID: String??
                if let rawOutputDeviceID = requested["outputDeviceID"] {
                    switch rawOutputDeviceID {
                    case .null:
                        requestedOutputDeviceUID = .some(nil)
                    case .string(let deviceID) where !deviceID.isEmpty:
                        guard let device = AudioOutputLatencyMonitor.availableOutputDevices().first(where: {
                            $0.id == deviceID
                        }) else {
                            throw AutomationParameterError.invalidValue("values.outputDeviceID")
                        }
                        requestedOutputDeviceUID = .some(device.uniqueID)
                    default:
                        throw AutomationParameterError.invalidValue("values.outputDeviceID")
                    }
                } else {
                    requestedOutputDeviceUID = nil
                }
                let current = appSession.automationAudioSettings()
                let expectedRevision = try parameters.string("expectedRevision")
                let currentRevision = automationAudioRevision(
                    current.gaplessSchedulingEnabled,
                    current.aacGaplessTrimEnabled,
                    current.outputDeviceUID
                )
                if let expectedRevision, expectedRevision != currentRevision {
                    return settingsRevisionConflict(for: request, expected: expectedRevision, actual: currentRevision)
                }
                let nextGapless = gapless ?? current.gaplessSchedulingEnabled
                let nextAACTrim = aacTrim ?? current.aacGaplessTrimEnabled
                let nextOutputDeviceUID = requestedOutputDeviceUID ?? current.outputDeviceUID
                let dryRun = try parameters.boolean("dryRun", default: false)
                let next = dryRun
                    ? (
                        gaplessSchedulingEnabled: nextGapless,
                        aacGaplessTrimEnabled: nextAACTrim,
                        outputDeviceUID: nextOutputDeviceUID
                    )
                    : appSession.updateAutomationAudioSettings(
                        gaplessSchedulingEnabled: gapless,
                        aacGaplessTrimEnabled: aacTrim,
                        outputDeviceUID: requestedOutputDeviceUID
                    )
                let values: [String: AutomationJSONValue] = [
                    "gaplessSchedulingEnabled": .boolean(next.gaplessSchedulingEnabled),
                    "aacGaplessTrimEnabled": .boolean(next.aacGaplessTrimEnabled),
                    "outputDeviceID": next.outputDeviceUID.map {
                        AutomationJSONValue.string(AudioOutputLatencyMonitor.stableDeviceID(for: $0))
                    } ?? .null
                ]
                return AutomationResponseSupport.encodeResult(AutomationSettingsResult(
                    libraryID: sessionAccess.activeSession(for: request)?.context.id,
                    values: values,
                    revision: automationAudioRevision(
                        next.gaplessSchedulingEnabled,
                        next.aacGaplessTrimEnabled,
                        next.outputDeviceUID
                    ),
                    applied: !dryRun,
                    dryRun: dryRun,
                    message: dryRun ? "Preview only. No audio setting was changed." : "Audio settings updated."
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        default:
            return AutomationResponseSupport.unsupportedMethod(for: request)
        }
    }

    private var defaultAutomationGlobalSettings: [String: AutomationJSONValue] {
        [
            "deferImportEnrichment": .boolean(true),
            "globalArtworkTintEnabled": .boolean(true),
            "audioVisualizationHDREnabled": .boolean(true),
            "dockProgressVisible": .boolean(true),
            "appearanceMode": .string("system")
        ]
    }

    private func automationSettingsValues(
        _ settings: LibraryScopedSettings
    ) -> [String: AutomationJSONValue] {
        let appSettings = AppSettings.shared
        return [
            "referencedTrackDeletePolicy": .string(
                settings.referencedTrackDeletePolicy.rawValue
            ),
            "deferImportEnrichment": .boolean(appSettings.deferImportEnrichment),
            "globalArtworkTintEnabled": .boolean(appSettings.globalArtworkTintEnabled),
            "audioVisualizationHDREnabled": .boolean(appSettings.audioVisualizationHDREnabled),
            "dockProgressVisible": .boolean(appSettings.dockProgressVisible),
            "appearanceMode": .string(appSettings.appearanceMode.rawValue)
        ]
    }

    private func normalizeAutomationSettings(
        _ requested: [String: AutomationJSONValue],
        referencedLibrary: Bool
    ) -> (values: [String: AutomationJSONValue], issues: [String]) {
        let supported = Set([
            "referencedTrackDeletePolicy",
            "deferImportEnrichment",
            "globalArtworkTintEnabled",
            "audioVisualizationHDREnabled",
            "dockProgressVisible",
            "appearanceMode"
        ])
        var normalized: [String: AutomationJSONValue] = [:]
        var issues: [String] = []
        if requested.isEmpty {
            issues.append("values must contain at least one supported setting.")
        }
        for (key, value) in requested {
            guard supported.contains(key) else {
                issues.append("Unsupported setting: \(key).")
                continue
            }
            switch key {
            case "referencedTrackDeletePolicy":
                guard referencedLibrary else {
                    issues.append("referencedTrackDeletePolicy applies only to a referenced library.")
                    continue
                }
                if case .string(let rawValue) = value,
                   let policy = ReferencedTrackDeletePolicy(rawValue: rawValue) {
                    normalized[key] = .string(policy.rawValue)
                } else {
                    issues.append("referencedTrackDeletePolicy must be onlyLibrary or recycleSource.")
                }
            case "deferImportEnrichment", "globalArtworkTintEnabled",
                 "audioVisualizationHDREnabled", "dockProgressVisible":
                if case .boolean = value {
                    normalized[key] = value
                } else {
                    issues.append("\(key) must be a boolean.")
                }
            case "appearanceMode":
                if case .string(let rawValue) = value,
                   AppSettings.AppearanceMode(rawValue: rawValue) != nil {
                    normalized[key] = .string(rawValue)
                } else {
                    issues.append("appearanceMode must be system, light or dark.")
                }
            default:
                break
            }
        }
        return (normalized, issues)
    }

    private func applyGlobalAutomationSettings(_ values: [String: AutomationJSONValue]) {
        let settings = AppSettings.shared
        for (key, value) in values {
            switch (key, value) {
            case ("deferImportEnrichment", .boolean(let enabled)):
                settings.deferImportEnrichment = enabled
            case ("globalArtworkTintEnabled", .boolean(let enabled)):
                settings.globalArtworkTintEnabled = enabled
            case ("audioVisualizationHDREnabled", .boolean(let enabled)):
                settings.audioVisualizationHDREnabled = enabled
            case ("dockProgressVisible", .boolean(let enabled)):
                settings.dockProgressVisible = enabled
            case ("appearanceMode", .string(let rawValue)):
                if let mode = AppSettings.AppearanceMode(rawValue: rawValue) {
                    settings.appearanceMode = mode
                }
            default:
                continue
            }
        }
    }

    private func automationSettingsRevision(
        _ values: [String: AutomationJSONValue]
    ) -> String {
        guard let data = try? AutomationWireCoding.encoder().encode(AutomationJSONValue.object(values)) else {
            return "settings-v2-unavailable"
        }
        let digest = SHA256.hash(data: data)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "settings-v2-\(digest)"
    }

    private func automationAudioRevision(
        _ gaplessEnabled: Bool,
        _ aacTrimEnabled: Bool,
        _ outputDeviceID: String?
    ) -> String {
        let value = "\(gaplessEnabled ? 1 : 0)|\(aacTrimEnabled ? 1 : 0)|\(outputDeviceID ?? "default")"
        let digest = SHA256.hash(data: Data(value.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "audio-v2-\(digest)"
    }

    private func settingsRevisionConflict(
        for request: AutomationRequest,
        expected: String,
        actual: String
    ) -> AutomationResponse {
        return .failure(
            for: request,
            error: AutomationError(
                code: .conflict,
                message: "The persistent automation settings changed since they were queried.",
                retryable: true,
                details: .object([
                    "expectedRevision": .string(expected),
                    "actualRevision": .string(actual)
                ])
            )
        )
    }
}
