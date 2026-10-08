import Foundation

/// Runs authorized disk operations away from MainActor. The caller retains
/// destination access and the Library operation until the continuation returns.
/// Cancellation never resumes a continuation before its disk work has finished.
nonisolated final class AutomationFileWorker: Sendable {
    struct Move: Sendable {
        let from: URL
        let destination: URL
    }

    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "player.automation.files", qos: .userInitiated)) {
        self.queue = queue
    }

    func copy(source: URL, trackID: UUID, to directory: URL) async throws -> URL {
        try await perform {
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw AutomationFileOperationError.fileUnavailable(trackID)
            }
            // Naming and copying share the serial queue, so concurrent exports
            // cannot choose the same available destination within this worker.
            let output = Self.uniqueExportURL(for: source.lastPathComponent, in: directory)
            try FileManager.default.copyItem(at: source, to: output)
            return output
        }
    }

    func move(_ plans: [Move]) async throws {
        try await perform {
            var applied: [Move] = []
            do {
                for plan in plans {
                    let parent = plan.destination.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: plan.from, to: plan.destination)
                    applied.append(plan)
                }
            } catch {
                for plan in applied.reversed() {
                    try? FileManager.default.moveItem(at: plan.destination, to: plan.from)
                }
                throw AutomationFileOperationError.operationFailed(error.localizedDescription)
            }
        }
    }

    private func perform<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func uniqueExportURL(for fileName: String, in directory: URL) -> URL {
        let sourceName = URL(fileURLWithPath: fileName)
        let baseName = sourceName.deletingPathExtension().lastPathComponent
        let fileExtension = sourceName.pathExtension
        var candidate = directory.appendingPathComponent(fileName, isDirectory: false)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let uniqueName = fileExtension.isEmpty
                ? "\(baseName) (\(suffix))"
                : "\(baseName) (\(suffix)).\(fileExtension)"
            candidate = directory.appendingPathComponent(uniqueName, isDirectory: false)
            suffix += 1
        }
        return candidate
    }
}
