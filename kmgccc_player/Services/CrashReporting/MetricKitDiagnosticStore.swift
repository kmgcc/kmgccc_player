import Foundation

actor MetricKitDiagnosticStore {
    static let shared = MetricKitDiagnosticStore()

    private let fileURL: URL
    private let maxRecords: Int
    private let maxBytes: Int

    init(
        rootURL: URL = CrashReportPaths.reportsRoot.appendingPathComponent("MetricKit", isDirectory: true),
        maxRecords: Int = 50,
        maxBytes: Int = 20 * 1024 * 1024
    ) {
        self.fileURL = rootURL.appendingPathComponent("queue.json")
        self.maxRecords = maxRecords
        self.maxBytes = maxBytes
    }

    func records() -> [MetricKitDiagnosticRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder.crashReportDecoder().decode(
                [MetricKitDiagnosticRecord].self,
                from: data
              ) else { return [] }
        return records.sorted { $0.envelope.intervalEnd < $1.envelope.intervalEnd }
    }

    func insertIfNeeded(_ record: MetricKitDiagnosticRecord) throws {
        var current = records()
        guard !current.contains(where: { $0.id == record.id }) else { return }
        current.append(record)
        current.sort { $0.envelope.intervalEnd > $1.envelope.intervalEnd }
        if current.count > maxRecords {
            current.removeLast(current.count - maxRecords)
        }
        try saveFitting(current)
    }

    func save(_ record: MetricKitDiagnosticRecord) throws {
        var current = records()
        if let index = current.firstIndex(where: { $0.id == record.id }) {
            current[index] = record
        } else {
            current.append(record)
        }
        try saveFitting(current)
    }

    func remove(reportID: String) throws {
        let filtered = records().filter { $0.id != reportID }
        try persist(filtered)
    }

    private func saveFitting(_ records: [MetricKitDiagnosticRecord]) throws {
        var fitting = records.sorted { $0.envelope.intervalEnd > $1.envelope.intervalEnd }
        while !fitting.isEmpty {
            let data = try JSONEncoder.crashReportEncoder().encode(fitting)
            if data.count <= maxBytes {
                try persist(data)
                return
            }
            fitting.removeLast()
        }
        try persist([])
    }

    private func persist(_ records: [MetricKitDiagnosticRecord]) throws {
        try persist(JSONEncoder.crashReportEncoder().encode(records))
    }

    private func persist(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
