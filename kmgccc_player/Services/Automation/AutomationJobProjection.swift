import Foundation
import PlayerAutomationProtocol

@MainActor
enum AutomationJobProjection {

    static func makeJobSummary(
        _ descriptor: LibraryOperationTaskDescriptor
    ) -> AutomationJobSummary {
        let kind: String
        switch descriptor.kind {
        case .importFiles: kind = "importFiles"
        case .libraryBundleExport: kind = "libraryBundleExport"
        case .embeddedTagWrite: kind = "embeddedTagWrite"
        case .sourceScan: kind = "sourceScan"
        case .ncmConversion: kind = "ncmConversion"
        case .enrichment: kind = "enrichment"
        case .automation: kind = "automation"
        case .indexUpdate: kind = "indexUpdate"
        case .other: kind = "other"
        }
        let state: AutomationJobState
        switch descriptor.state {
        case .queued: state = .queued
        case .running: state = .running
        case .checkpointed: state = .checkpointed
        case .completed: state = .completed
        case .partialFailure: state = .partialFailure
        case .failed: state = .failed
        case .cancelled: state = .cancelled
        }
        return AutomationJobSummary(
            id: descriptor.id,
            kind: kind,
            libraryID: descriptor.libraryID,
            state: state,
            createdAt: descriptor.createdAt,
            startedAt: descriptor.startedAt,
            finishedAt: descriptor.finishedAt,
            checkpoint: descriptor.lastCheckpointLabel,
            completedCount: descriptor.completedCount ?? 0,
            totalCount: descriptor.totalCount,
            currentPhase: descriptor.currentPhase,
            failures: descriptor.partialFailureSummaries,
            failedItemIDs: descriptor.failedItemIDs,
            retryable: descriptor.retrySpec != nil
                && (descriptor.state == .failed
                    || descriptor.state == .partialFailure
                    || descriptor.state == .cancelled),
            result: descriptor.result
        )
    }
}
