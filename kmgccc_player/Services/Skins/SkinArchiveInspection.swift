import Foundation

/// Inspect the central directory before invoking the platform extractor.
enum SkinArchiveInspection {
    static let maximumExpandedBytes = 512 * 1024 * 1024
    static let maximumFiles = 4096

    static func validate(_ url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumExpandedBytes else { throw failure("压缩包超过大小限制") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard data.count >= 22 else { throw failure("ZIP 目录无效") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if u32(offset) == 0x06054b50, offset + 22 + u16(offset + 20) == data.count { end = offset; break }
        }
        guard let end, u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == u16(end + 10) else { throw failure("ZIP 目录无效") }
        let count = u16(end + 10), directorySize = u32(end + 12), start = u32(end + 16)
        guard count > 0, count <= maximumFiles, start >= 0, start + directorySize <= end else { throw failure("ZIP 文件数或目录无效") }
        var offset = start, total = 0
        var names: Set<String> = []
        for _ in 0..<count {
            guard offset + 46 <= end, u32(offset) == 0x02014b50 else { throw failure("ZIP 条目无效") }
            let nameLength = u16(offset + 28), extraLength = u16(offset + 30), commentLength = u16(offset + 32)
            let next = offset + 46 + nameLength + extraLength + commentLength
            guard next <= end, let name = String(data: data[(offset + 46)..<(offset + 46 + nameLength)], encoding: .utf8) else { throw failure("ZIP 路径编码无效") }
            let normalized = name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).decomposedStringWithCanonicalMapping.lowercased()
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0"),
                  !name.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }), names.insert(normalized).inserted else { throw failure("ZIP 路径无效：\(name)") }
            let mode = (u32(offset + 38) >> 16) & 0xf000
            guard mode == 0 || mode == 0x8000 || mode == 0x4000 else { throw failure("ZIP 包含链接或特殊文件") }
            guard u16(offset + 8) & 1 == 0, [0, 8].contains(u16(offset + 10)), u16(offset + 34) == 0 else { throw failure("ZIP 压缩方式不支持") }
            let expanded = u32(offset + 24)
            let compressed = u32(offset + 20), local = u32(offset + 42)
            guard local + 30 <= start, u32(local) == 0x04034b50,
                  u16(local + 6) == u16(offset + 8), u16(local + 8) == u16(offset + 10) else { throw failure("ZIP 本地目录不一致") }
            let localNameLength = u16(local + 26), localExtraLength = u16(local + 28)
            let payload = local + 30 + localNameLength + localExtraLength
            guard payload + compressed <= start,
                  data[(local + 30)..<(local + 30 + localNameLength)] == data[(offset + 46)..<(offset + 46 + nameLength)] else { throw failure("ZIP 路径记录不一致") }
            total += expanded
            guard total <= maximumExpandedBytes, expanded <= 128 * 1024 * 1024 else { throw failure("ZIP 展开内容超过大小限制") }
            offset = next
        }
        guard offset == start + directorySize else { throw failure("ZIP 目录长度无效") }
    }
    private static func failure(_ message: String) -> SkinPackageError { .archive(message) }
}
