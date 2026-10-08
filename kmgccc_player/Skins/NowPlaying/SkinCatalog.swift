import Observation
import SwiftUI

/// One live collection serves selection, routing and capability lookup.
@Observable
@MainActor
final class SkinCatalog {
    private(set) var skins: [any NowPlayingSkin]
    let components = SkinComponentCatalog()
    let parameters = SkinParameterStore()
    private var nativePresets: [String: any NowPlayingSkin] = [:]
    private var revisions: [String: UInt64] = [:]

    func revision(for skinID: String) -> UInt64 { revisions[skinID, default: 0] }

    func reload(_ skinID: String) throws {
        guard let skin = registeredSkin(for: skinID) else { return }
        if let package = skin as? PackagedSkin, case .installed = package.origin {
            try packages.reloadPackage(skinID)
        } else {
            revisions[skinID, default: 0] &+= 1
        }
    }
    @ObservationIgnored lazy var packages = SkinPackageStore(catalog: self)

    init(skins: [any NowPlayingSkin]) {
        self.skins = skins
    }

    @discardableResult
    func register(_ skin: any NowPlayingSkin) -> Bool {
        guard !skins.contains(where: { $0.id == skin.id }) else { return false }
        skins.append(skin)
        return true
    }

    func registerNativePreset(_ skin: any NowPlayingSkin) {
        nativePresets[skin.id] = skin
        for part in SkinPresetComponent.Part.allCases {
            components.register("builtin.\(skin.id).\(part.rawValue)") { snapshot, configuration in
                SkinPresetComponent(renderer: skin, part: part, snapshot: snapshot, configuration: configuration)
            }
        }
    }

    @discardableResult
    func registerBundled(_ renderer: any NowPlayingSkin, version: String = "1.0.0") -> Bool {
        guard registeredSkin(for: renderer.id) == nil else { return false }
        registerNativePreset(renderer)
        return register(PackagedSkin(
            manifest: .init(version: version, descriptor: renderer.descriptor,
                            nativePreset: renderer.id, parameters: renderer.parameterDefinitions),
            origin: .bundled, renderer: renderer
        ))
    }

    func nativePreset(for id: String?) -> (any NowPlayingSkin)? {
        id.flatMap { nativePresets[$0] }
    }

    func install(_ skin: PackagedSkin) {
        revisions[skin.id, default: 0] &+= 1
        if let index = skins.firstIndex(where: { $0.id == skin.id }) {
            skins[index] = skin
        } else {
            skins.append(skin)
        }
    }

    func removeInstalled(_ skinID: String) {
        guard let skin = registeredSkin(for: skinID) as? PackagedSkin,
              case .installed = skin.origin else { return }
        skins.removeAll { $0.id == skinID }
        revisions[skinID, default: 0] &+= 1
    }

    func registeredSkin(for id: String) -> (any NowPlayingSkin)? {
        skins.first { $0.id == id }
    }

    func skins(for surface: SkinSurface) -> [any NowPlayingSkin] {
        skins.filter { $0.descriptor.surfaces.contains(surface) }
    }
}
