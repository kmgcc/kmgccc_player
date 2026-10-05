import SwiftUI

/// Authors may provide these operations using official components or their own controls.
/// Only recovery operations missing from a fullscreen scene receive host affordances.
enum SkinSceneControl: String, Hashable {
    case playPause, previous, next, lyricsToggle, fullscreen, quickPanel
}

struct SkinSceneControlsKey: PreferenceKey {
    static var defaultValue: Set<SkinSceneControl> = []
    static func reduce(value: inout Set<SkinSceneControl>, nextValue: () -> Set<SkinSceneControl>) {
        value.formUnion(nextValue())
    }
}

extension View {
    func skinProvidesControls(_ controls: Set<SkinSceneControl>) -> some View {
        preference(key: SkinSceneControlsKey.self, value: controls)
    }
}
