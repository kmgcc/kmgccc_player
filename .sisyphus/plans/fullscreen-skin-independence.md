# Fullscreen Skin Independence Plan

## TL;DR

> **Goal**: Enable independent skin selection for fullscreen mode, decoupling it from Now Playing skin choice while preserving fullscreen-specific configurations.
>
> **Deliverables**:
> - New `selectedFullscreenSkinID` configuration in AppSettings
> - Fullscreen-compatible skin filtering via protocol extension
> - Skin picker UI in SettingsView's fullscreen section
> - FullscreenPlayerView updated to use independent skin selection
>
> **Estimated Effort**: Medium (5-7 tasks, ~2-3 hours)
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
4. **Skin Compatibility**: Add `isFullscreenCompatible` marker to protocol
5. **Future Extensibility**: Support adding fullscreen-only skins later

---

## Work Objectives

### Core Objective
Implement independent skin selection for fullscreen mode, allowing users to choose a different skin for fullscreen than for Now Playing view, while maintaining fullscreen-specific configuration options.

### Concrete Deliverables
- Extended `NowPlayingSkin` protocol with `isFullscreenCompatible` property
- New `selectedFullscreenSkinID` configuration property in AppSettings
- `SkinRegistry` method to filter fullscreen-compatible skins
- Skin picker UI in SettingsView's fullscreen section
- Updated FullscreenPlayerView using independent skin selection
- Fullscreen-specific skin options support (similar to Now Playing)

### Definition of Done
- [ ] User can select different skin for fullscreen vs Now Playing in Settings
- [ ] Fullscreen mode displays the selected skin correctly
- [ ] Default fullscreen skin is Cassette on first launch
- [ ] Existing users' settings remain valid (backward compatible)
- [ ] Skin-specific options (if any) appear in fullscreen settings
- [ ] All 3 existing skins work in fullscreen mode

### Must Have
- Independent skin configuration storage
- UI for selecting fullscreen skin in Settings
- FullscreenPlayerView using the new configuration
- Protocol extension for compatibility marking

### Must NOT Have (Guardrails)
- No breaking changes to Now Playing skin system
- No modification of existing skin implementations beyond protocol conformance
- No removal of fullscreen-specific configuration options
- No changes to skin rendering logic beyond ID selection

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

- [ ] 1. Extend NowPlayingSkin Protocol with Compatibility Marker

  **What to do**:
  - Add `isFullscreenCompatible: Bool` property to `NowPlayingSkin` protocol
  - Update all 3 existing skin implementations to return `true`
  - Ensure protocol maintains backward compatibility

  **Must NOT do**:
  - Do not change existing skin behavior or rendering
  - Do not remove any existing protocol methods

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
  - [ ] All 3 skin implementations compile and return `true`
  - [ ] No breaking changes to existing code

  **QA Scenarios**:
  ```
  Scenario: Protocol Extension Compiles
    Tool: Bash (swift build)
    Steps:
      1. Run xcodebuild -project kmgccc_player.xcodeproj -scheme myPlayer2 build
    Expected Result: Build succeeds with no errors
    Evidence: .sisyphus/evidence/task-1-build-success.log

  Scenario: All Skins Return True
    Tool: Read (verify code)
    Steps:
      1. Read each skin file and verify isFullscreenCompatible returns true
    Expected Result: All 3 skins have the property returning true
    Evidence: .sisyphus/evidence/task-1-skins-compatible.md
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

- [ ] 3. Add Fullscreen Skin Filtering to SkinRegistry

  **What to do**:
  - Add `fullscreenSkins: [any NowPlayingSkin]` computed property
  - Add `defaultFullscreenSkinID: String` constant
  - Add `fullscreenSkin(for id: String) -> any NowPlayingSkin` method
  - Add `fullscreenOptions: [SkinOption]` for UI picker

  **Must NOT do**:
  - Do not remove existing skin registration methods
  - Do not hardcode skin list - use isFullscreenCompatible filter

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
  - [ ] `defaultFullscreenSkinID` set to "kmgccc.cassette"
  - [ ] `fullscreenSkin(for:)` method works like existing `skin(for:)`
  - [ ] `fullscreenOptions` computed property for UI

  **QA Scenarios**:
  ```
  Scenario: Fullscreen Skin Filtering
    Tool: Read (code verification)
    Steps:
      1. Read SkinRegistry.swift changes
      2. Verify filter uses isFullscreenCompatible
    Expected Result: Methods correctly filter skins
    Evidence: .sisyphus/evidence/task-3-registry-methods.md
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
  - Verify fullscreen-specific configurations still work

  **Must NOT do**:
  - Do not remove support for Now Playing skin (keep as fallback for migration?)
  - Do not break fullscreen-specific configs (scale, lyrics, etc.)

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

  Scenario: Fullscreen Configs Preserved
    Tool: Manual app testing
    Steps:
      1. Set fullscreenArtworkScale to 1.2
      2. Enter fullscreen mode
      3. Verify artwork scales correctly
      4. Change to different skin
      5. Verify scale still applies
    Expected Result: Configurations work with independent skin
    Evidence: .sisyphus/evidence/task-6-configs-preserved.png
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

  **Acceptance Criteria**:
  - [ ] All 3 skins work correctly in fullscreen
  - [ ] Edge cases handled gracefully
  - [ ] No crashes or visual glitches
  - [ ] Settings persist across app restarts

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
  - Must Have: All 4 items present (protocol, config, registry, UI, fullscreen)
  - Must NOT Have: No breaking changes to Now Playing
  - Tasks: All 7 tasks completed
  - Evidence: All QA evidence files exist
  Output: `Must Have [4/4] | Must NOT Have [4/4] | Tasks [7/7] | VERDICT`

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
  6. Verify fullscreen configs still work
  Output: `Scenarios [6/6 pass] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  Verify no scope creep:
  - Check no Now Playing code modified unnecessarily
  - Verify only specified files changed
  - Confirm no additional features added
  Output: `Scope [COMPLIANT/ISSUES] | VERDICT`

---

## Commit Strategy

| Task | Commit Message | Files |
|------|----------------|-------|
| 1 | `feat(skin): add isFullscreenCompatible to NowPlayingSkin protocol` | `Skins/NowPlaying/NowPlayingSkin.swift`, `*Skin.swift` |
| 2 | `feat(settings): add selectedFullscreenSkinID configuration` | `Models/AppSettings.swift` |
| 3 | `feat(skin): add fullscreen skin registry methods` | `Skins/NowPlaying/SkinRegistry.swift` |
| 4 | `feat(settings): add fullscreen skin picker UI` | `Views/Settings/SettingsView.swift` |
| 5 | `feat(settings): add fullscreen skin options UI` | `Views/Settings/SettingsView.swift` |
| 6 | `feat(fullscreen): use independent skin selection` | `Views/Fullscreen/FullscreenPlayerView.swift` |
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
- [ ] All 3 skin implementations return `true`
- [ ] `selectedFullscreenSkinID` configuration added to AppSettings
- [ ] `SkinRegistry` has fullscreen filtering methods
- [ ] SettingsView shows fullscreen skin picker
- [ ] SettingsView shows fullscreen skin options (when applicable)
- [ ] FullscreenPlayerView uses independent skin selection
- [ ] Default fullscreen skin is Cassette
- [ ] Fullscreen-specific configs (scale, lyrics) still work
- [ ] All skins work correctly in fullscreen mode
- [ ] Build succeeds with no errors
- [ ] No breaking changes to Now Playing skin system

---

## File References

**Key Files to Modify**:
1. `myPlayer2/Skins/NowPlaying/NowPlayingSkin.swift` - Protocol extension
2. `myPlayer2/Skins/NowPlaying/SkinRegistry.swift` - Registry methods
3. `myPlayer2/Skins/NowPlaying/*Skin.swift` - Conformance updates
4. `myPlayer2/Models/AppSettings.swift` - Configuration storage
5. `myPlayer2/Views/Settings/SettingsView.swift` - UI additions
6. `myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift` - Integration

**No Changes Needed**:
- NowPlayingHostView (uses existing skin system)
- SkinManager (can remain focused on Now Playing)
- ThemeStore (unchanged)
