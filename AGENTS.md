# AGENTS.md - kmgccc_player

Guidelines for AI agents working on this macOS music player codebase.

## Project Overview

**kmgccc_player** is a macOS 26+ music player built with SwiftUI, SwiftData, and AVAudioEngine. It features Liquid Glass UI design, AMLL lyrics integration, and LDDC lyrics fetching.

- **Language**: Swift (macOS 26+)
- **UI Framework**: SwiftUI with Liquid Glass materials
- **Persistence**: SwiftData + JSON sidecars
- **Audio**: AVAudioEngine + AVAudioPlayerNode
- **Architecture**: MVVM + Repository + Service layers

## Build Commands

```bash
# Build the app
xcodebuild -project kmgccc_player.xcodeproj -scheme myPlayer2 -configuration Debug build

# Build for release
xcodebuild -project kmgccc_player.xcodeproj -scheme myPlayer2 -configuration Release build

# Open in Xcode
open kmgccc_player.xcodeproj

# Build LDDC Python server (lyrics fetching)
cd LDDC_Fetch_Core
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

**Note**: No unit tests currently exist in this project. Test manually via Xcode preview or running the app.

## Code Style Guidelines

### File Headers
Every Swift file must include:
```swift
//
//  Filename.swift
//  myPlayer2
//
//  kmgccc_player - Brief description
//

import statements...
```

### Import Ordering
```swift
import AppleFrameworks  // AVFoundation, MediaPlayer, AppKit, etc.
import Foundation        // Always present
import SwiftData         // Data persistence
import SwiftUI           // UI framework
```

### Type Naming
- **Protocols**: `ServiceNameProtocol`, `RepositoryProtocol`
- **ViewModels**: `FeatureViewModel` (e.g., `PlayerViewModel`)
- **Services**: `FeatureService` or `ServiceName` (e.g., `AudioPlaybackService`)
- **Repositories**: `DataStoreRepository` (e.g., `SwiftDataLibraryRepository`)
- **Views**: `FeatureView` or `FeatureElementView` (e.g., `PlaylistDetailView`)
- **Models**: Simple nouns (e.g., `Track`, `Playlist`)

### Architecture Patterns

**ViewModels** (`@Observable @MainActor`):
```swift
@Observable
@MainActor
final class PlayerViewModel {
    private let playbackService: AudioPlaybackServiceProtocol
    // Expose computed properties from service
}
```

**Services** (Protocol + Real + Stub):
```swift
@MainActor
protocol AudioPlaybackServiceProtocol: AnyObject { ... }

@Observable @MainActor final class AVAudioPlaybackService: AudioPlaybackServiceProtocol { ... }
final class StubAudioPlaybackService: AudioPlaybackServiceProtocol { ... }
```

**Actors for Concurrent Code**:
```swift
actor LDDCClient {
    // Thread-safe network operations
}
```

### Access Control
- Use `private` for implementation details
- Use `private(set)` for observable state that ViewModels mutate
- Use `internal` (default) for cross-module access
- Avoid `public`/`open` unless designing a framework

### Error Handling
```swift
// Use Result type for async operations
func fetchData() async -> Result<Data, Error> { ... }

// Log errors with descriptive messages
print("❌ Failed to resolve bookmark for track \(title): \(error)")

// Prefer throwing for service layer
func search() async throws -> Response { ... }
```

### SwiftData Models
```swift
@Model
final class Track {
    @Attribute(.unique) var id: UUID
    var title: String
    @Relationship(inverse: \Playlist.tracks) var playlists: [Playlist] = []
    
    init(...) { self.id = id ... }
}
```

### Liquid Glass UI (CRITICAL)
**Always use standardized glass modifiers** - never write raw `.glassEffect`:

```swift
// ❌ WRONG - Never do this
.glassEffect(.clear, in: .circle)
.overlay(Circle().stroke(...))

// ✅ CORRECT - Use extension methods
.liquidGlassCircle(
    colorScheme: colorScheme,
    accentColor: themeStore.accentColor,
    prominence: .standard
)
```

Available modifiers in `GlassPillView.swift`:
- `.liquidGlassPill(...)` - Capsule-shaped glass
- `.liquidGlassRect(...)` - Rounded rectangle glass  
- `.liquidGlassCircle(...)` - Circular glass

**Design tokens** (`GlassStyleTokens.swift`):
- Use `GlassStyleTokens.headerBarHeight` (60pt)
- Use `GlassStyleTokens.headerControlHeight` (36pt)
- Use `GlassStyleTokens.miniPlayerHeight` (50pt)
- Use `.prominent` for main controls, `.standard` for secondary

## Project Structure

```
myPlayer2/
├── Models/           # SwiftData @Model classes
├── ViewModels/       # @Observable @MainActor view models
├── Views/            # SwiftUI Views
│   ├── Layout/       # Main layout containers
│   ├── Library/      # Playlist/track list UI
│   ├── NowPlaying/   # Playback view
│   ├── Lyrics/       # AMLL WebView integration
│   ├── Controls/     # Reusable control components
│   └── Settings/     # Settings panels
├── Services/         # Business logic & external integrations
│   ├── Audio/        # Playback, level meter
│   ├── Library/      # File management, scanning
│   ├── Lyrics/       # AMLL bridge
│   ├── LDDC/         # Lyrics fetching client
│   └── NowPlaying/   # Media keys integration
├── Repositories/     # Data access layer (SwiftData)
├── Utilities/        # Constants, tokens, helpers
└── Skins/            # Now playing skin implementations
```

## Environment & Dependencies

- **Platform**: macOS 26.0+
- **Xcode**: Latest version required (for macOS 26 SDK)
- **Python**: 3.10+ for LDDC_Fetch_Core (lyrics server)
- **External**: AMLL (AppleMusic-Like Lyrics) Web component in `Resources/AMLL/`

## Key Conventions

1. **@MainActor**: All ViewModels and UI-updating Services must use `@MainActor`
2. **Environment Injection**: Pass services via `.environment()` in `AppRootView.swift`
3. **File Comments**: Use emoji prefixes for log output: `❌` error, `⚠️` warning, `✅` success
4. **Localization**: Use `NSLocalizedString` with descriptive comment keys
5. **Preview Providers**: Always provide `PreviewProvider` with stub dependencies

## Data Persistence

- **SwiftData**: Primary persistence for Track/Playlist models
- **JSON Sidecars**: Each track has `meta.json` for metadata portability
- **Security Bookmarks**: Use security-scoped bookmarks for sandbox file access
- **Library Path**: `~/Music/kmgccc_player Library/`

## Testing Strategy

Currently no automated tests. Test manually via:
- Xcode Canvas previews (use stub implementations)
- Running the app on macOS 26+ device/vm
- Testing audio with various formats (MP3, M4A, FLAC, etc.)

## Resources

- `LIQUID_GLASS_SPEC.md` - UI design system specification
- `ARCHITECTURE.md` - Detailed architecture documentation
- `README.md` - Project overview (Chinese)
