import Foundation

enum SidebarSetBarItemKind: String, Codable, CaseIterable, Identifiable {
    case settings
    case appearance
    case fullscreen
    case volumeTarget
    case soundEffects
    case externalPlayback
    case backgroundPreparation
    case latencyCompensation
    case hdr
    case motionArtwork
    case systemAppearance
    case lyrics
    case separator

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .settings: return "设置"
        case .appearance: return "深浅色切换"
        case .fullscreen: return "全屏"
        case .volumeTarget: return "音量目标"
        case .soundEffects: return "音效处理"
        case .externalPlayback: return "从外部播放"
        case .backgroundPreparation: return "空闲时提前准备"
        case .latencyCompensation: return "延迟补偿"
        case .hdr: return "HDR 效果"
        case .motionArtwork: return "动态封面"
        case .systemAppearance: return "跟随系统外观"
        case .lyrics: return "歌词"
        case .separator: return "分割线"
        }
    }

    func systemImage(isDark: Bool) -> String {
        switch self {
        case .settings: return "gear"
        case .appearance: return isDark ? "moon" : "sun.max"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        case .volumeTarget: return "speaker.wave.2"
        case .soundEffects: return "waveform"
        case .externalPlayback: return "music.note.tv"
        case .backgroundPreparation: return "clock.arrow.circlepath"
        case .latencyCompensation: return "waveform.path"
        case .hdr: return "sparkles"
        case .motionArtwork: return "livephoto"
        case .systemAppearance: return "circle.lefthalf.filled"
        case .lyrics: return "quote.bubble"
        case .separator: return "minus"
        }
    }
}

struct SidebarSetBarItem: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: SidebarSetBarItemKind
}

/// Ordered buttons and invisible group boundaries. Separators never consume a button slot.
struct SidebarSetBarConfiguration: Codable, Equatable {
    static let maximumButtonCount = 4
    static let defaultsKey = "sidebarSetBarConfiguration"
    static let defaultValue = Self(items: [
        SidebarSetBarItem(kind: .settings),
        SidebarSetBarItem(kind: .fullscreen),
    ])

    private(set) var items: [SidebarSetBarItem]

    init(items: [SidebarSetBarItem]) {
        var normalized: [SidebarSetBarItem] = []
        var buttonCount = 0
        var identifiers = Set<UUID>()
        var buttonKinds = Set<SidebarSetBarItemKind>()
        for item in items {
            guard !identifiers.contains(item.id) else { continue }
            if item.kind == .separator {
                guard let last = normalized.last, last.kind != .separator else { continue }
            } else {
                guard buttonCount < Self.maximumButtonCount,
                      buttonKinds.insert(item.kind).inserted else { continue }
                buttonCount += 1
            }
            identifiers.insert(item.id)
            normalized.append(item)
        }
        if normalized.last?.kind == .separator {
            normalized.removeLast()
        }
        self.items = normalized
    }

    var buttonCount: Int { items.filter { $0.kind != .separator }.count }

    var availableKinds: [SidebarSetBarItemKind] {
        SidebarSetBarItemKind.allCases.filter { kind in
            kind == .separator || !items.contains(where: { $0.kind == kind })
        }
    }

    func inserting(_ item: SidebarSetBarItem, at index: Int) -> Self {
        guard item.kind == .separator || buttonCount < Self.maximumButtonCount else { return self }
        guard item.kind == .separator || !items.contains(where: { $0.kind == item.kind }) else { return self }
        var updated = items
        updated.insert(item, at: min(max(0, index), updated.count))
        return Self(items: updated)
    }

    func removing(_ id: UUID) -> Self {
        Self(items: items.filter { $0.id != id })
    }

    /// Index refers to the original order, so moving past oneself does not shift the target.
    func moving(_ id: UUID, to index: Int) -> Self {
        guard let source = items.firstIndex(where: { $0.id == id }) else { return self }
        var updated = items
        let item = updated.remove(at: source)
        let destination = index > source ? index - 1 : index
        updated.insert(item, at: min(max(0, destination), updated.count))
        return Self(items: updated)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(items: try container.decode([SidebarSetBarItem].self, forKey: .items))
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }
}
