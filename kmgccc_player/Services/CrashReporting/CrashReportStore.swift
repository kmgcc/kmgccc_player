import Foundation

nonisolated enum CrashReportStoreError: Error {
    case invalidReportID
    case reportTooLarge
}

nonisolated enum CrashReportPaths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "kmgccc_player"
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    static var reportsRoot: URL {
        applicationSupport.appendingPathComponent("CrashReports", isDirectory: true)
    }
}

actor CrashReportStore {
    static let shared = CrashReportStore()

    private let fileManager: FileManager
    private let rootURL: URL
    private let pendingURL: URL
    private let corruptURL: URL
    private let maxReports: Int
    private let maxBytes: Int

    init(
        rootURL: URL = CrashReportPaths.reportsRoot,
        fileManager: FileManager = .default,
        maxReports: Int = 10,
        maxBytes: Int = 10 * 1024 * 1024
    ) {
        self.rootURL = rootURL
        self.pendingURL = rootURL.appendingPathComponent("Pending", isDirectory: true)
        self.corruptURL = rootURL.appendingPathComponent("Corrupt", isDirectory: true)
        self.fileManager = fileManager
        self.maxReports = maxReports
        self.maxBytes = maxBytes
    }

    func save(_ record: CrashReportRecord) throws {
        guard UUID(uuidString: record.report.reportID) != nil else {
            throw CrashReportStoreError.invalidReportID
        }
        try ensureDirectories()
        let data = try JSONEncoder.crashReportEncoder().encode(record)
        guard data.count <= maxBytes else {
            throw CrashReportStoreError.reportTooLarge
        }
        try data.write(to: fileURL(for: record.report.reportID), options: .atomic)
        try enforceCapacity()
    }

    func records() -> [CrashReportRecord] {
        do {
            try ensureDirectories()
            let urls = try recordFileURLs()
            var decoded: [CrashReportRecord] = []
            for url in urls {
                do {
                    let data = try Data(contentsOf: url)
                    decoded.append(try JSONDecoder.crashReportDecoder().decode(CrashReportRecord.self, from: data))
                } catch {
                    quarantine(url)
                }
            }
            return decoded.sorted { $0.report.occurredAt > $1.report.occurredAt }
        } catch {
            return []
        }
    }

    func record(reportID: String) -> CrashReportRecord? {
        guard UUID(uuidString: reportID) != nil,
              let data = try? Data(contentsOf: fileURL(for: reportID)) else {
            return nil
        }
        return try? JSONDecoder.crashReportDecoder().decode(CrashReportRecord.self, from: data)
    }

    func remove(reportID: String) throws {
        guard UUID(uuidString: reportID) != nil else {
            throw CrashReportStoreError.invalidReportID
        }
        try fileManager.removeItem(at: fileURL(for: reportID))
    }

    func removeAll() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: pendingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: corruptURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = rootURL
        try? root.setResourceValues(values)
    }

    private func fileURL(for reportID: String) -> URL {
        pendingURL.appendingPathComponent(reportID.lowercased()).appendingPathExtension("json")
    }

    private func recordFileURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: pendingURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    private func quarantine(_ url: URL) {
        let destination = corruptURL.appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.lowercased()).json"
        )
        try? fileManager.moveItem(at: url, to: destination)
    }

    private func enforceCapacity() throws {
        struct Candidate {
            let url: URL
            let size: Int
            let modifiedAt: Date
            let isCompleted: Bool
        }

        var candidates: [Candidate] = try recordFileURLs().map { url in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let data = try Data(contentsOf: url)
            let record = try? JSONDecoder.crashReportDecoder().decode(CrashReportRecord.self, from: data)
            let state = record?.technicalUploadState
            return Candidate(
                url: url,
                size: values.fileSize ?? data.count,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                isCompleted: state == .uploaded || state == .permanentlyFailed || state == .declined
            )
        }

        var totalBytes = candidates.reduce(0) { $0 + $1.size }
        candidates.sort {
            if $0.isCompleted != $1.isCompleted { return $0.isCompleted }
            return $0.modifiedAt < $1.modifiedAt
        }

        while candidates.count > maxReports || totalBytes > maxBytes {
            let removed = candidates.removeFirst()
            try fileManager.removeItem(at: removed.url)
            totalBytes -= removed.size
        }
    }
}
