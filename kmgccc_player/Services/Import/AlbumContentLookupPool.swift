import Foundation

/// Owned by the library's existing enrichment service and shared with immediate
/// import. Subscribers can cancel independently from the shared provider request.
@MainActor
final class AlbumContentLookupPool {
    let covers = AlbumLookupTasks<ImportCoverLookupOutcome>()
    let metadata = AlbumLookupTasks<ImportAlbumMetadataOutcome>()
    let artwork = AlbumLookupTasks<ImportAlbumArtworkOutcome>()
    func close() { covers.close(); metadata.close(); artwork.close() }
}

@MainActor
final class AlbumLookupTasks<Value: Sendable> {
    private final class Entry {
        let task: Task<Value, Never>
        var subscribers = Set<UUID>()
        var completedAt: Date?
        init(task: Task<Value, Never>) { self.task = task }
    }
    private var entries: [String: Entry] = [:]

    func value(for key: String, operation: @escaping @MainActor @Sendable () async -> Value) async -> Value {
        let now = Date()
        entries = entries.filter { _, entry in
            entry.completedAt.map { now.timeIntervalSince($0) < 60 } ?? true
        }
        if entries.count >= 32 {
            for old in entries.keys.sorted() where entries[old]?.subscribers.isEmpty == true {
                entries[old] = nil
                if entries.count < 32 { break }
            }
        }
        let entry: Entry
        if let existing = entries[key] { entry = existing }
        else { entry = Entry(task: Task { await operation() }); entries[key] = entry }
        let subscriber = UUID()
        entry.subscribers.insert(subscriber)
        let result = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: { [weak self] in
            Task { @MainActor in self?.release(key: key, subscriber: subscriber, cancelled: true) }
        }
        entry.completedAt = Date()
        release(key: key, subscriber: subscriber, cancelled: Task.isCancelled)
        return result
    }
    private func release(key: String, subscriber: UUID, cancelled: Bool) {
        guard let entry = entries[key], entry.subscribers.remove(subscriber) != nil else { return }
        if cancelled && entry.subscribers.isEmpty && entry.completedAt == nil {
            entry.task.cancel()
            entries[key] = nil
        }
    }
    func close() {
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
    }
}
