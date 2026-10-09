import Foundation
import PlayerAutomationProtocol

@MainActor
struct AutomationLoudnessHandler {
    private weak var appSession: AppSessionHost?
    init(appSession: AppSessionHost?) { self.appSession = appSession }

    func handle(_ request: AutomationRequest) async -> AutomationResponse {
        let access = AutomationSessionAccess(appSession: appSession)
        guard let session = access.activeSession(for: request) else {
            return access.noActiveLibraryResponse(for: request)
        }
        do {
            let parameters = try AutomationParameters(request)
            var ids = try parameters.uuidArray("trackIDs", required: request.method == AutomationMethod.audioLoudnessAnalyze, maximumCount: request.method == AutomationMethod.audioLoudnessGet ? 200 : 5000)
            let availableIDs = Set(session.libraryViewModel.allTracks.map(\.id))
            guard ids.allSatisfy({ availableIDs.contains($0) }) else {
                throw AutomationParameterError.invalidValue("trackIDs")
            }
            if request.method == AutomationMethod.audioLoudnessGet {
                let offset = try parameters.integer("offset", default: 0)
                let limit = try parameters.integer("limit", default: 100)
                guard (0...1_000_000).contains(offset), (1...200).contains(limit) else { throw AutomationParameterError.outOfRange("pagination") }
                let all = session.libraryViewModel.allTracks
                let usesLibraryPage = ids.isEmpty
                if usesLibraryPage { ids = all.dropFirst(offset).prefix(limit).map(\.id) }
                let records = await session.loadLoudnessRecords(trackIDs: ids)
                guard appSession?.activeLibraryBinding.activeSession === session else {
                    return .failure(for: request, error: AutomationError(code: .conflict, message: "The active library changed.", retryable: true))
                }
                let ordered = ids.compactMap { records[$0] }
                var encoded = try AutomationWireCoding.decoder().decode(AutomationJSONValue.self,
                    from: AutomationWireCoding.encoder().encode(ordered))
                let includeEnergyHistogram = try parameters.boolean("includeEnergyHistogram", default: false)
                if !includeEnergyHistogram, case .array(let items) = encoded {
                    encoded = .array(items.map { item in
                        guard case .object(var fields) = item, case .object(var measurement) = fields["measurement"] else { return item }
                        measurement.removeValue(forKey: "gatedBlockEnergyHistogram")
                        fields["measurement"] = .object(measurement)
                        return .object(fields)
                    })
                }
                return AutomationResponseSupport.encodeResult(AutomationJSONValue.object([
                    "records": encoded,
                    "nextOffset": usesLibraryPage && offset + ids.count < all.count ? .number(Double(offset + ids.count)) : .null,
                    "requestedTrackIDs": .array(ids.map { .string($0.uuidString) }),
                    "missingTrackIDs": .array(ids.filter { records[$0] == nil }.map { .string($0.uuidString) }),
                    "validity": .string("cachedSnapshot; playback verifies source identity before use"),
                    "currentNormalization": .object(session.audioNormalizationState)
                ]), for: request)
            }
            let dryRun = try parameters.boolean("dryRun", default: false)
            if dryRun {
                return AutomationResponseSupport.encodeResult(AutomationJSONValue.object([
                    "dryRun": .boolean(true), "applied": .boolean(false),
                    "trackCount": .number(Double(ids.count)), "currentPlaybackUnchanged": .boolean(true)
                ]), for: request)
            }
            guard let job = session.startAutomationLoudnessAnalyze(trackIDs: ids) else {
                return .failure(for: request, error: AutomationError(code: .conflict,
                    message: "The library cannot accept a loudness scan now.", retryable: true))
            }
            return AutomationResponseSupport.encodeResult(AutomationJSONValue.object([
                "job": try AutomationWireCoding.decoder().decode(AutomationJSONValue.self,
                    from: AutomationWireCoding.encoder().encode(AutomationJobProjection.makeJobSummary(job))),
                "currentPlaybackUnchanged": .boolean(true)
            ]), for: request)
        } catch {
            return AutomationResponseSupport.invalidParameters(for: request, error: error)
        }
    }
}
