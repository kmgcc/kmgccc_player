import Foundation

/// Bookmarked author directories are linked, never copied into or deleted with installations.
@MainActor
final class SkinDevelopmentDirectories {
    private unowned let catalog: SkinCatalog
    private let defaults: UserDefaults
    private let key = "skin.developmentDirectories.v2"
    private var tasks: [String: Task<Void, Never>] = [:]
    private var scopes: [String: URL] = [:]

    init(catalog: SkinCatalog, defaults: UserDefaults = .standard) { self.catalog = catalog; self.defaults = defaults }

    func restore() {
        for data in defaults.array(forKey: key) as? [Data] ?? [] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale) else { continue }
            do { try attach(url) } catch { Log.warning("Skin development directory failed: \(error.localizedDescription)", category: .ui) }
        }
    }

    @discardableResult
    func attach(_ directory: URL) throws -> String {
        let scoped = directory.startAccessingSecurityScopedResource()
        do {
            let package = try catalog.packages.validateDirectory(directory)
            if let existing = catalog.registeredSkin(for: package.id) {
                guard let existing = existing as? PackagedSkin, case .development(let current) = existing.origin, current == directory else {
                    throw SkinPackageError.invalidManifest("已有相同 ID 的皮肤")
                }
            }
            let bookmark = try directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            var bookmarks = defaults.array(forKey: key) as? [Data] ?? []
            if !bookmarks.contains(bookmark) { bookmarks.append(bookmark); defaults.set(bookmarks, forKey: key) }
            tasks[package.id]?.cancel()
            if let old = scopes.removeValue(forKey: package.id) { old.stopAccessingSecurityScopedResource() }
            if scoped { scopes[package.id] = directory }
            catalog.install(package)
            watch(directory, id: package.id)
            return package.id
        } catch {
            if scoped { directory.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func detach(_ id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        if let url = scopes.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
        let retained = (defaults.array(forKey: key) as? [Data] ?? []).filter { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
                  let package = catalog.registeredSkin(for: id) as? PackagedSkin,
                  case .development(let directory) = package.origin else { return true }
            return url != directory
        }
        defaults.set(retained, forKey: key)
    }

    private func watch(_ directory: URL, id: String) {
        tasks[id] = Task { @MainActor [weak self] in
            var previous = Self.fingerprint(directory)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                let next = Self.fingerprint(directory)
                guard next != previous else { continue }
                previous = next
                do { try self?.catalog.packages.reloadPackage(id) }
                catch { Log.warning("Skin reload kept the previous program: \(error.localizedDescription)", category: .ui) }
            }
        }
    }

    private static func fingerprint(_ directory: URL) -> String {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return "" }
        var values: [String] = []
        for case let url as URL in files {
            if values.count > SkinArchiveInspection.maximumFiles { break }
            if let resource = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
                values.append("\(url.path):\(resource.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0):\(resource.fileSize ?? 0)")
            }
        }
        return values.sorted().joined(separator: "|")
    }
}
