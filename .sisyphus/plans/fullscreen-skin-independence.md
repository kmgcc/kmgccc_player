# Fullscreen Skin Independence Plan

## TL;DR

> **Goal**: Enable independent skin selection for fullscreen mode, decoupling it from Now Playing skin choice while preserving fullscreen-specific configurations, and supporting future fullscreen-only skins.
>
> **Deliverables**:
> - Dual compatibility markers in protocol (`isFullscreenCompatible` + `isNowPlayingCompatible`)
> - All 3 existing skins set to both compatible
> - New `selectedFullscreenSkinID` configuration in AppSettings
> - SkinRegistry filtering for both contexts (supports fullscreen-only skins)
> - Skin picker UI in SettingsView's fullscreen section
> - FullscreenPlayerView updated with independent selection + preserved configs
>
> **Estimated Effort**: Medium (7 tasks, ~2-3 hours)
> **Parallel Execution**: YES - Tasks 1-3 can run in parallel
> **Critical Path**: Protocol Extension → Configuration → Settings UI → Fullscreen View Update

---

## Context

### Original Request
用户希望将全屏模式的皮肤选择独立出来，从设置页面为全屏选择独立皮肤，保留全屏专有配置（如封面缩放、歌词样式等），并支持未来为全屏单独添加皮肤。

### Current State Analysis
**Skin System Architecture**:
- `NowPlayingSkin` protocol defines the skin interface with id, name, makeBackground/Artwork/Overlay methods
- `SkinRegistry` statically registers 3 skins (Cassette, RotatingCover, ClassicLED)
- `SkinManager` manages skin selection via `AppSettings.selectedNowPlayingSkinID`
- `FullscreenPlayerView` currently inherits Now Playing skin choice

**Configuration Storage**:
- `AppSettings` uses `@AppStorage` + UserDefaults for persistence
- Settings are organized in `SettingsView` with 7 categories including `.fullscreen`
- Fullscreen-specific configs: `fullscreenArtworkScale`, `fullscreenLyricsMode`, etc.

### Design Decisions (Confirmed)
1. **Default Behavior**: Independent skin selection (not following Now Playing)
2. **Default Skin**: `kmgccc.cassette` as fullscreen default
3. **Settings Location**: `SettingsCategory.fullscreen` section
4. **Skin Compatibility**: Add `isFullscreenCompatible` and `isNowPlayingCompatible` markers to protocol
5. **Existing Skins**: All 3 existing skins (Cassette, RotatingCover, ClassicLED) set to both compatible
6. **Future Extensibility**: Support adding fullscreen-only skins (isFullscreenCompatible=true, isNowPlayingCompatible=false)
7. **Fullscreen Configs**: All existing fullscreen-specific configurations (artworkScale, lyricsMode, etc.) preserved

---

## Work Objectives

### Core Objective
Implement independent skin selection for fullscreen mode, allowing users to choose a different skin for fullscreen than for Now Playing view, while maintaining fullscreen-specific configuration options.

### Concrete Deliverables
- Extended `NowPlayingSkin` protocol with **dual compatibility markers**:
  - `isFullscreenCompatible: Bool` - For fullscreen mode
  - `isNowPlayingCompatible: Bool` - For Now Playing (prevents fullscreen-only skins appearing there)
- All 3 existing skin implementations set to **both compatible** (`true`)
- New `selectedFullscreenSkinID` configuration property in AppSettings
- `SkinRegistry` methods:
  - `fullscreenSkins` - Filter by isFullscreenCompatible
  - `nowPlayingSkins` - Filter by isNowPlayingCompatible (for future)
  - `fullscreenSkin(for:)` - Lookup by ID
- Skin picker UI in SettingsView's fullscreen section
- Updated FullscreenPlayerView using independent skin selection
- **Preserved fullscreen-specific configurations** (scale, lyrics, dimming, etc.)

### Definition of Done
- [ ] User can select different skin for fullscreen vs Now Playing in Settings
- [ ] Fullscreen mode displays the selected skin correctly
- [ ] Default fullscreen skin is Cassette on first launch
- [ ] Existing users' settings remain valid (backward compatible)
- [ ] Skin-specific options (if any) appear in fullscreen settings
- [ ] **All 3 existing skins work in fullscreen mode** (all set to both compatible)
- [ ] **All fullscreen-specific configurations preserved**:
  - [ ] `fullscreenArtworkScale` - Cover scaling works correctly
  - [ ] `fullscreenLyricsMode` - Lyrics display mode preserved
  - [ ] `fullscreenDimmingIntensity` - Background dimming functional
  - [ ] `fullscreenShowLyrics` - Lyrics visibility toggle works
  - [ ] `fullscreenLyricsFontSize` - Font sizing applies correctly
- [ ] **Future extensibility**: Protocol supports fullscreen-only skins (isNowPlayingCompatible=false)

### Must Have
- Dual compatibility markers (`isFullscreenCompatible` + `isNowPlayingCompatible`)
- All 3 existing skins set to both compatible
- Independent skin configuration storage (`selectedFullscreenSkinID`)
- UI for selecting fullscreen skin in Settings
- FullscreenPlayerView using the new configuration
- **All fullscreen-specific configurations preserved**
- SkinRegistry filtering methods for both contexts

### Must NOT Have (Guardrails)
- No breaking changes to Now Playing skin system
- No modification of existing skin implementations beyond adding properties
- No removal of fullscreen-specific configuration options
- No changes to skin rendering logic beyond ID selection
- No loss of fullscreen-specific configuration functionality

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** — All verification is agent-executed.

### Test Decision
- **Infrastructure exists**: NO (no unit tests in project)
- **Automated tests**: Tests-after (manual QA scenarios)
- **Framework**: Manual verification via app execution

### QA Policy
Every task includes agent-executed QA scenarios. Evidence saved to `.sisyphus/evidence/`.

- **Frontend/UI**: Playwright or manual app testing
- **Configuration**: Verify UserDefaults persistence
- **Integration**: Test fullscreen skin selection and display

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Foundation - Can Run in Parallel):
├── Task 1: Extend NowPlayingSkin protocol with isFullscreenCompatible
├── Task 2: Add selectedFullscreenSkinID to AppSettings
└── Task 3: Update SkinRegistry with fullscreen filtering methods

Wave 2 (UI Layer - After Wave 1):
├── Task 4: Add fullscreen skin picker to SettingsView
└── Task 5: Add fullscreen skin options support

Wave 3 (Integration - After Wave 2):
└── Task 6: Update FullscreenPlayerView to use independent skin

Wave 4 (Verification):
└── Task 7: Integration testing and edge case verification
```

### Dependency Matrix
| Task | Depends On | Blocks |
|------|------------|--------|
| 1 (Protocol) | — | 3 |
| 2 (Config) | — | 4, 6 |
| 3 (Registry) | 1 | 4, 6 |
| 4 (Settings UI) | 2, 3 | 6 |
| 5 (Options UI) | 2 | 6 |
| 6 (Fullscreen View) | 2, 3, 4, 5 | 7 |
| 7 (Verification) | 6 | — |

### Agent Dispatch Summary
- **Tasks 1-3**: `quick` category - Protocol extension, config addition, registry methods
- **Tasks 4-5**: `visual-engineering` category - SwiftUI Settings modifications
- **Task 6**: `unspecified-high` category - FullscreenPlayerView integration
- **Task 7**: `unspecified-high` category - Manual QA and verification

---

## TODOs

- [ ] 1. Extend NowPlayingSkin Protocol with Dual Compatibility Markers

  **What to do**:
  - Add `isFullscreenCompatible: Bool` property to `NowPlayingSkin` protocol
  - Add `isNowPlayingCompatible: Bool` property to `NowPlayingSkin` protocol  
  - Update all 3 existing skin implementations to return `true` for BOTH properties
  - This enables fullscreen-only skins in the future (isFullscreenCompatible=true, isNowPlayingCompatible=false)

  **Must NOT do**:
  - Do not change existing skin behavior or rendering
  - Do not remove any existing protocol methods
  - Do not set any skin to only fullscreen compatible yet (keep all dual-compatible for now)

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Reason**: Simple protocol extension with minimal changes
  - **Skills**: None required

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: Task 3
  - **Blocked By**: None

  **References**:
  - Pattern: `/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Skins/NowPlaying/NowPlayingSkin.swift` - Existing protocol definition
  - Update: `ClassicLEDSkin.swift`, `RotatingCoverSkin.swift`, `KmgcccCassetteSkin.swift` - Add property

  **Acceptance Criteria**:
  - [ ] `NowPlayingSkin` protocol has `isFullscreenCompatible` property
  - [ ] `NowPlayingSkin` protocol has `isNowPlayingCompatible` property
  - [ ] All 3 skin implementations return `true` for BOTH properties
  - [ ] No breaking changes to existing code

  **QA Scenarios**:
  ```
  Scenario: Protocol Extension Compiles
    Tool: Bash (swift build)
    Steps:
      1. Run xcodebuild -project kmgccc_player.xcodeproj -scheme myPlayer2 build
    Expected Result: Build succeeds with no errors
    Evidence: .sisyphus/evidence/task-1-build-success.log

  Scenario: Both Compatibility Markers Present
    Tool: Read (verify code)
    Steps:
      1. Read NowPlayingSkin.swift and verify both properties exist
      2. Read each skin file and verify both return true
    Expected Result: Protocol has dual markers, all skins dual-compatible
    Evidence: .sisyphus/evidence/task-1-dual-markers.md
  ```

  **Commit**: YES
  - Message: `feat(skin): add isFullscreenCompatible to NowPlayingSkin protocol`
  - Files: `Skins/NowPlaying/NowPlayingSkin.swift`, `Skins/NowPlaying/*Skin.swift`

- [ ] 2. Add selectedFullscreenSkinID Configuration to AppSettings

  **What to do**:
  - Add `selectedFullscreenSkinID` property to `AppSettings` class
  - Use `@AppStorage("fullscreenSkin")` for persistence
  - Set default value to `kmgccc.cassette`
  - Follow existing pattern from `selectedNowPlayingSkinID`

  **Must NOT do**:
  - Do not remove or modify existing skin configuration
  - Do not use different storage mechanism than @AppStorage

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Reason**: Configuration property addition following existing patterns
  - **Skills**: None required

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: Tasks 4, 6
  - **Blocked By**: None

  **References**:
  - Pattern: `/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Models/AppSettings.swift` - See `selectedNowPlayingSkinID` implementation
  - Default: Use `"kmgccc.cassette"` as default value

  **Acceptance Criteria**:
  - [ ] Property added with @AppStorage("fullscreenSkin")
  - [ ] Default value is "kmgccc.cassette"
  - [ ] Follows same pattern as selectedNowPlayingSkinID

  **QA Scenarios**:
  ```
  Scenario: Configuration Property Exists
    Tool: Read (code verification)
    Steps:
      1. Read AppSettings.swift and verify property exists
      2. Verify it uses @AppStorage("fullscreenSkin")
    Expected Result: Property correctly defined with default value
    Evidence: .sisyphus/evidence/task-2-config-added.md

  Scenario: Persistence Works
    Tool: Bash (UserDefaults verification)
    Steps:
      1. Build and run app
      2. Check UserDefaults contains "fullscreenSkin" key after first launch
    Expected Result: Key exists with default value
    Evidence: .sisyphus/evidence/task-2-persistence-verified.txt
  ```

  **Commit**: YES
  - Message: `feat(settings): add selectedFullscreenSkinID configuration`
  - Files: `Models/AppSettings.swift`

- [ ] 3. Add Dual Skin Filtering to SkinRegistry

  **What to do**:
  - Add `fullscreenSkins: [any NowPlayingSkin]` computed property (filter by isFullscreenCompatible)
  - Add `nowPlayingSkins: [any NowPlayingSkin]` computed property (filter by isNowPlayingCompatible)
  - Add `defaultFullscreenSkinID: String` constant
  - Add `fullscreenSkin(for id: String) -> any NowPlayingSkin` method
  - Add `fullscreenOptions: [SkinOption]` for UI picker
  - Ensure existing `skins` property continues to work for backward compatibility

  **Must NOT do**:
  - Do not remove existing skin registration methods
  - Do not hardcode skin lists - use compatibility filters
  - Do not break Now Playing skin selection (ensure it uses isNowPlayingCompatible filter)

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Reason**: Registry method additions following existing patterns
  - **Skills**: None required

  **Parallelization**:
  - **Can Run In Parallel**: YES (depends on Task 1)
  - **Parallel Group**: Wave 1
  - **Blocks**: Tasks 4, 6
  - **Blocked By**: Task 1

  **References**:
  - Pattern: `/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Skins/NowPlaying/SkinRegistry.swift` - Copy existing patterns
  - Filter: Use `skins.filter { $0.isFullscreenCompatible }`

  **Acceptance Criteria**:
  - [ ] `fullscreenSkins` property returns all compatible skins
  - [ ] `nowPlayingSkins` property returns all compatible skins (for future filtering)
  - [ ] `defaultFullscreenSkinID` set to "kmgccc.cassette"
  - [ ] `fullscreenSkin(for:)` method works like existing `skin(for:)`
  - [ ] `fullscreenOptions` computed property for UI
  - [ ] Both filters use correct compatibility properties

  **QA Scenarios**:
  ```
  Scenario: Dual Skin Filtering
    Tool: Read (code verification)
    Steps:
      1. Read SkinRegistry.swift changes
      2. Verify fullscreenSkins uses isFullscreenCompatible
      3. Verify nowPlayingSkins uses isNowPlayingCompatible
    Expected Result: Both filters correctly separate skin contexts
    Evidence: .sisyphus/evidence/task-3-dual-filters.md
  ```

  **Commit**: YES
  - Message: `feat(skin): add fullscreen skin registry methods`
  - Files: `Skins/NowPlaying/SkinRegistry.swift`

- [ ] 4. Add Fullscreen Skin Picker to SettingsView

  **What to do**:
  - Add `@State private var fullscreenSkin: String` in SettingsView
  - Add skin picker UI in `fullscreenSection` (similar to nowPlayingSection)
  - Use `Picker` with `SkinRegistry.fullscreenOptions`
  - Add sync logic with `AppSettings.selectedFullscreenSkinID`

  **Must NOT do**:
  - Do not modify nowPlaying skin picker
  - Do not use different UI pattern than existing skin picker

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
  - **Reason**: SwiftUI Settings UI modifications following existing patterns
  - **Skills**: None required

  **Parallelization**:
  - **Can Run In Parallel**: NO (needs Task 2, 3)
  - **Parallel Group**: Wave 2
  - **Blocks**: Task 6
  - **Blocked By**: Tasks 2, 3

  **References**:
  - Pattern: `/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Views/Settings/SettingsView.swift` - See `nowPlayingSection` implementation (lines ~350-450)
  - UI: Use `.pickerStyle(.radioGroup)` like existing skin picker
  - Sync: Follow `appearanceSyncLogic` pattern

  **Acceptance Criteria**:
  - [ ] Skin picker appears in fullscreen settings section
  - [ ] Picker shows all fullscreen-compatible skins
  - [ ] Selection persists via AppSettings
  - [ ] UI matches existing skin picker style

  **QA Scenarios**:
  ```
  Scenario: Fullscreen Skin Picker UI
    Tool: Screenshot verification
    Steps:
      1. Open Settings → Fullscreen
      2. Verify skin picker is visible with all 3 options
      3. Select different skin
      4. Verify selection persists after reopening settings
    Expected Result: Picker works correctly with all skins
    Evidence: .sisyphus/evidence/task-4-picker-ui.png
  ```

  **Commit**: YES
  - Message: `feat(settings): add fullscreen skin picker UI`
  - Files: `Views/Settings/SettingsView.swift`

- [ ] 5. Add Fullscreen Skin-Specific Options UI

  **What to do**:
  - Add dynamic skin options display in fullscreen settings
  - Similar to nowPlayingSection: show per-skin settings if available
  - Check `SkinRegistry.fullscreenSkin(for:).settingsView`
  - Add appropriate GroupBox wrapper

  **Must NOT do**:
  - Do not duplicate options from nowPlaying (skins share same options)
  - Do not show options for skins that don't have settingsView

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
  - **Reason**: SwiftUI conditional rendering following existing patterns
  - **Skills**: None required

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 4)
  - **Parallel Group**: Wave 2
  - **Blocks**: Task 6
  - **Blocked By**: Task 2

  **References**:
  - Pattern: `SettingsView.swift` nowPlayingSection - See options display pattern
  - Implementation: Use `if let optionsView = ...` pattern

  **Acceptance Criteria**:
  - [ ] Skin options appear when selected skin has settingsView
  - [ ] Options are specific to fullscreen context
  - [ ] UI matches existing GroupBox pattern

  **QA Scenarios**:
  ```
  Scenario: Skin Options Display
    Tool: Screenshot verification
    Steps:
      1. Select Cassette skin
      2. Verify Cassette options appear (kmg look toggle, etc.)
      3. Select Rotating Cover
      4. Verify appropriate options appear
    Expected Result: Options display correctly per skin
    Evidence: .sisyphus/evidence/task-5-skin-options.png
  ```

  **Commit**: YES (can group with Task 4)
  - Message: `feat(settings): add fullscreen skin options UI`
  - Files: `Views/Settings/SettingsView.swift`

- [ ] 6. Update FullscreenPlayerView to Use Independent Skin

  **What to do**:
  - Replace `selectedNowPlayingSkinID` usage with `selectedFullscreenSkinID`
  - Update `skinArtworkArea()` method to use fullscreen skin registry
  - Ensure `makeContext()` uses correct skin selection
  - **PRESERVE all fullscreen-specific configurations**:
    - `fullscreenArtworkScale` - Cover scale factor (0.8-1.5)
    - `fullscreenLyricsMode` - Lyrics display mode
    - `fullscreenDimmingIntensity` - Background dimming
    - `fullscreenShowLyrics` - Show/hide lyrics
    - `fullscreenLyricsFontSize` - Lyrics font size
  - Ensure these configs continue to work with new skin selection

  **Must NOT do**:
  - Do not remove or modify fullscreen-specific configuration options
  - Do not break existing fullscreen behavior beyond skin selection change

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
  - **Reason**: Core integration logic change in complex view
  - **Skills**: None required

  **Parallelization**:
  - **Can Run In Parallel**: NO (needs Tasks 2, 3, 4, 5)
  - **Parallel Group**: Wave 3
  - **Blocks**: Task 7
  - **Blocked By**: Tasks 2, 3, 4, 5

  **References**:
    - File: `/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift`
  - Lines: Look for `selectedNowPlayingSkinID` usage (~line 180-200)
  - Method: `skinArtworkArea()` and `makeContext()`
  - Registry: Use `SkinRegistry.fullscreenSkin(for:)` instead of `skinManager.skin(for:)`

  **Acceptance Criteria**:
  - [ ] FullscreenPlayerView uses `selectedFullscreenSkinID`
  - [ ] Fullscreen displays skin selected in Settings
  - [ ] Fullscreen-specific configs (scale, lyrics) still work
  - [ ] Different skins can be selected for Now Playing vs Fullscreen

  **QA Scenarios**:
  ```
  Scenario: Independent Skin Selection
    Tool: Manual app testing
    Steps:
      1. Set Now Playing skin to Cassette
      2. Set Fullscreen skin to Rotating Cover
      3. Open Now Playing - verify Cassette displayed
      4. Enter Fullscreen - verify Rotating Cover displayed
    Expected Result: Different skins display correctly
    Evidence: .sisyphus/evidence/task-6-independent-skins.png

  Scenario: Fullscreen Artwork Scale Preserved
    Tool: Manual app testing
    Steps:
      1. Set fullscreenArtworkScale to 1.2
      2. Enter fullscreen mode
      3. Verify artwork scales correctly
      4. Change to different skin
      5. Verify scale still applies
    Expected Result: Artwork scaling works with independent skin
    Evidence: .sisyphus/evidence/task-6-scale-preserved.png

  Scenario: Fullscreen Lyrics Config Preserved
    Tool: Manual app testing
    Steps:
      1. Set fullscreenShowLyrics to true
      2. Set fullscreenLyricsFontSize to 32
      3. Enter fullscreen mode
      4. Verify lyrics visible with correct font size
      5. Change skin and verify settings persist
    Expected Result: Lyrics configuration preserved across skin changes
    Evidence: .sisyphus/evidence/task-6-lyrics-preserved.png

  Scenario: Fullscreen Dimming Preserved
    Tool: Manual app testing
    Steps:
      1. Set fullscreenDimmingIntensity to 0.5
      2. Enter fullscreen mode
      3. Verify background dimming applies correctly
    Expected Result: Dimming works with all skins
    Evidence: .sisyphus/evidence/task-6-dimming-preserved.png
  ```

  **Commit**: YES
  - Message: `feat(fullscreen): use independent skin selection`
  - Files: `Views/Fullscreen/FullscreenPlayerView.swift`

- [ ] 7. Integration Testing and Edge Case Verification

  **What to do**:
  - Test all 3 skins in fullscreen mode
  - Test edge cases: invalid skin ID, migration from old settings
  - Verify backward compatibility
  - Test skin-specific options in fullscreen

  **Must NOT do**:
  - Do not skip edge case testing
  - Do not assume migration works without testing

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
  - **Reason**: Comprehensive verification of integration
  - **Skills**: None required

  **Parallelization**:
  - **Can Run In Parallel**: NO (needs Task 6)
  - **Parallel Group**: Wave 4
  - **Blocks**: None
  - **Blocked By**: Task 6

  **Edge Cases to Test**:
  1. Fresh install - default skin should be Cassette
  2. Invalid skin ID in UserDefaults - should fallback to default
  3. Skin with no settingsView - should not crash
  4. Rapid skin switching - should handle gracefully
  5. Enter fullscreen while track changes - should remain stable
  6. **Future extensibility** - Test that protocol supports fullscreen-only skins
  7. All fullscreen-specific configs work with each of the 3 skins

  **Acceptance Criteria**:
  - [ ] All 3 skins work correctly in fullscreen
  - [ ] All fullscreen-specific configs preserved and functional
  - [ ] Edge cases handled gracefully
  - [ ] No crashes or visual glitches
  - [ ] Settings persist across app restarts
  - [ ] Dual compatibility system ready for future fullscreen-only skins

  **QA Scenarios**:
  ```
  Scenario: All Skins in Fullscreen
    Tool: Manual app testing
    Steps:
      1. Test Cassette skin in fullscreen
      2. Test Rotating Cover skin in fullscreen
      3. Test Classic LED skin in fullscreen
      4. Verify each displays correctly
    Expected Result: All skins work
    Evidence: .sisyphus/evidence/task-7-all-skins-tested.md

  Scenario: Invalid Skin ID Fallback
    Tool: Manual testing with UserDefaults manipulation
    Steps:
      1. Set invalid skin ID in UserDefaults
      2. Launch app and enter fullscreen
      3. Verify falls back to default Cassette
    Expected Result: Graceful fallback
    Evidence: .sisyphus/evidence/task-7-fallback-tested.txt
  ```

  **Commit**: NO (verification only, no code changes)

---

## Final Verification Wave

> Run these 4 review agents in PARALLEL after ALL implementation tasks.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. Verify:
  - Must Have: 
    - Dual compatibility markers in protocol (isFullscreenCompatible + isNowPlayingCompatible)
    - All 3 skins set to both compatible
    - Independent fullscreen skin configuration
    - Fullscreen skin picker UI
    - FullscreenPlayerView integration
    - All fullscreen-specific configs preserved
  - Must NOT Have: 
    - No breaking changes to Now Playing
    - No loss of fullscreen-specific configurations
    - No hardcoded skin lists
  - Tasks: All 7 tasks completed
  - Evidence: All QA evidence files exist
  Output: `Must Have [6/6] | Must NOT Have [3/3] | Tasks [7/7] | VERDICT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `xcodebuild` to verify compilation. Check for:
  - No new warnings
  - No force unwraps
  - Follows existing code patterns
  - Proper access control
  Output: `Build [PASS/FAIL] | Warnings [N] | Issues [N] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high`
  Test the complete feature:
  1. Fresh install - verify default is Cassette
  2. Change fullscreen skin in Settings
  3. Verify different from Now Playing skin
  4. Enter fullscreen - verify correct skin displays
  5. Test all 3 skins
  6. Verify fullscreen configs (scale, lyrics, dimming) work with all skins
  7. Verify protocol supports future fullscreen-only skins
  Output: `Scenarios [7/7 pass] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  Verify no scope creep and future extensibility:
  - Check no Now Playing code modified unnecessarily
  - Verify only specified files changed
  - Confirm no additional features added
  - Verify dual compatibility system ready for fullscreen-only skins
  Output: `Scope [COMPLIANT/ISSUES] | Future Ready [YES/NO] | VERDICT`

---

## Commit Strategy

| Task | Commit Message | Files |
|------|----------------|-------|
| 1 | `feat(skin): add dual compatibility markers to NowPlayingSkin protocol` | `NowPlayingSkin.swift`, `ClassicLEDSkin.swift`, `RotatingCoverSkin.swift`, `KmgcccCassetteSkin.swift` |
| 2 | `feat(settings): add selectedFullscreenSkinID configuration` | `AppSettings.swift` |
| 3 | `feat(skin): add fullscreen and nowPlaying skin registry filters` | `SkinRegistry.swift` |
| 4 | `feat(settings): add fullscreen skin picker UI` | `SettingsView.swift` |
| 5 | `feat(settings): add fullscreen skin options UI` | `SettingsView.swift` |
| 6 | `feat(fullscreen): use independent skin selection with preserved configs` | `FullscreenPlayerView.swift` |
| 7 | — | — |

---

## Success Criteria

### Verification Commands
```bash
# Build verification
xcodebuild -project kmgccc_player.xcodeproj -scheme myPlayer2 -configuration Debug build

# Expected: ** BUILD SUCCEEDED **
```

### Final Checklist
- [ ] `isFullscreenCompatible` added to NowPlayingSkin protocol
- [ ] `isNowPlayingCompatible` added to NowPlayingSkin protocol
- [ ] All 3 skin implementations return `true` for BOTH properties
- [ ] SkinRegistry has `nowPlayingSkins` filter (for future fullscreen-only skins)
- [ ] `selectedFullscreenSkinID` configuration added to AppSettings
- [ ] `SkinRegistry` has fullscreen filtering methods
- [ ] SettingsView shows fullscreen skin picker
- [ ] SettingsView shows fullscreen skin options (when applicable)
- [ ] FullscreenPlayerView uses independent skin selection
- [ ] **All fullscreen-specific configs preserved and working**:
  - [ ] `fullscreenArtworkScale` - Cover scale works with all skins
  - [ ] `fullscreenLyricsMode` - Lyrics mode preserved
  - [ ] `fullscreenDimmingIntensity` - Dimming works correctly
  - [ ] `fullscreenShowLyrics` - Lyrics visibility toggle works
  - [ ] `fullscreenLyricsFontSize` - Font size applies correctly
- [ ] Default fullscreen skin is Cassette
- [ ] All 3 skins work correctly in fullscreen mode
- [ ] Build succeeds with no errors
- [ ] No breaking changes to Now Playing skin system

---

## File References

**Key Files to Modify**:
1. `myPlayer2/Skins/NowPlaying/NowPlayingSkin.swift` - Protocol extension (add dual compatibility markers)
2. `myPlayer2/Skins/NowPlaying/SkinRegistry.swift` - Registry methods (fullscreen + nowPlaying filters)
3. `myPlayer2/Skins/NowPlaying/ClassicLEDSkin.swift` - Set both compatible=true
4. `myPlayer2/Skins/NowPlaying/RotatingCoverSkin.swift` - Set both compatible=true
5. `myPlayer2/Skins/NowPlaying/KmgcccCassetteSkin.swift` - Set both compatible=true
6. `myPlayer2/Models/AppSettings.swift` - Configuration storage (fullscreenSkin)
7. `myPlayer2/Views/Settings/SettingsView.swift` - UI additions (fullscreen skin picker)
8. `myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift` - Integration (use fullscreen skin + preserve configs)

**Key Behaviors to Preserve**:
- Fullscreen-specific configurations remain functional:
  - `fullscreenArtworkScale` (0.8-1.5 range)
  - `fullscreenLyricsMode` (lyrics display style)
  - `fullscreenDimmingIntensity` (background dimming)
  - `fullscreenShowLyrics` (toggle visibility)
  - `fullscreenLyricsFontSize` (font sizing)

**Future Extensibility**:
- Fullscreen-only skins: Set `isFullscreenCompatible=true`, `isNowPlayingCompatible=false`
- NowPlaying-only skins: Set `isFullscreenCompatible=false`, `isNowPlayingCompatible=true`
- Dual-compatible skins: Set both to `true` (current 3 skins)
