# SeamlessMarqueeText Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `MarqueeText` (TimelineView / 30fps, jump-back-to-start) with `SeamlessMarqueeText` (Task + `withAnimation(.linear)`, dual-copy seamless loop) across all three call sites.

**Architecture:** `SeamlessMarqueeText` renders two identical `Text` copies in an `HStack` when text overflows its container. A single async `Task` (MainActor) drives each scroll cycle via one `withAnimation(.linear(duration:))` call, sleeps through the pause phase via `Task.sleep`, then resets offset with `withTransaction(disablesAnimations)` and yields twice before the next cycle. All parameter changes cancel and restart the loop.

**Tech Stack:** SwiftUI, AppKit (NSFont for width measurement), Swift Concurrency (`async Task`, `Task.yield()`, `Task.sleep(for:)`)

---

## File Map

| Action | File | Purpose |
|--------|------|---------|
| **Create** | `myPlayer2/Views/Controls/SeamlessMarqueeText.swift` | New unified marquee component |
| **Modify** | `myPlayer2/Views/MiniPlayer/MiniPlayerView.swift` | Replace 2× `MarqueeText` |
| **Modify** | `myPlayer2/Views/Fullscreen/FullscreenMiniPlayerView.swift` | Replace 2× `MarqueeText` |
| **Modify** | `myPlayer2/Views/Library/TrackRowView.swift` | Replace 2× `MarqueeText` |
| **Delete** | `myPlayer2/Views/Controls/MarqueeText.swift` | Old implementation, removed after migration |

---

## Task 1: Create SeamlessMarqueeText — static scaffold

**Files:**
- Create: `myPlayer2/Views/Controls/SeamlessMarqueeText.swift`

- [ ] Create the file with the full public API and static (non-animating) rendering. No loop task yet — that comes in Task 3.

```swift
// myPlayer2/Views/Controls/SeamlessMarqueeText.swift
import AppKit
import SwiftUI

struct SeamlessMarqueeText: View {

    enum Style: Equatable {
        case body
        case subheadline
        case caption
        case custom(fontSize: CGFloat)
    }

    let text: String
    let style: Style
    let fontWeight: Font.Weight
    let color: Color

    var gap: CGFloat = 40.0            // points between copy 1 and copy 2
    var speed: CGFloat = 40.0          // points per second
    var pauseDuration: TimeInterval = 5.0
    var shouldAnimate: Bool = true
    var enablesContentTransition: Bool = false

    // MARK: - Body (static only — animation wired in Tasks 2–3)

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            textLabel
                .truncationMode(.tail)
                .frame(width: width, alignment: .leading)
                .clipped()
        }
        .frame(height: lineHeight)
    }

    // MARK: - Text rendering (shared by static and marquee modes)

    @ViewBuilder
    private var textLabel: some View {
        let base = Text(text)
            .font(swiftUIFont)
            .fontWeight(fontWeight)
            .foregroundStyle(color)
            .lineLimit(1)
        if enablesContentTransition {
            base
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: text)
        } else {
            base
        }
    }

    // MARK: - Font helpers

    private var swiftUIFont: Font {
        switch style {
        case .body:            return .body
        case .subheadline:     return .subheadline
        case .caption:         return .caption
        case .custom(let sz):  return .system(size: sz)
        }
    }

    var nsFont: NSFont {
        switch style {
        case .body:
            return NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                weight: nsWeight)
        case .subheadline:
            return NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: nsWeight)
        case .caption:
            return NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: nsWeight)
        case .custom(let sz):
            return NSFont.systemFont(ofSize: sz, weight: nsWeight)
        }
    }

    private var nsWeight: NSFont.Weight {
        switch fontWeight {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }

    var lineHeight: CGFloat {
        let f = nsFont
        return max(1, f.ascender - f.descender + f.leading)
    }
}

// MARK: - Convenience initializers (match current MarqueeText call sites)

extension SeamlessMarqueeText {
    /// Style-based initializer — used by MiniPlayerView and TrackRowView.
    init(
        text: String,
        style: Style = .body,
        fontWeight: Font.Weight = .regular,
        color: Color = .primary,
        shouldAnimate: Bool = true,
        enablesContentTransition: Bool = false
    ) {
        self.text = text
        self.style = style
        self.fontWeight = fontWeight
        self.color = color
        self.shouldAnimate = shouldAnimate
        self.enablesContentTransition = enablesContentTransition
    }

    /// fontSize-based initializer — used by FullscreenMiniPlayerView (scaled sizes).
    init(
        text: String,
        fontSize: CGFloat,
        fontWeight: Font.Weight = .regular,
        color: Color = .primary,
        shouldAnimate: Bool = true,
        enablesContentTransition: Bool = false
    ) {
        self.text = text
        self.style = .custom(fontSize: fontSize)
        self.fontWeight = fontWeight
        self.color = color
        self.shouldAnimate = shouldAnimate
        self.enablesContentTransition = enablesContentTransition
    }
}

// MARK: - Preview

#Preview("SeamlessMarqueeText – Static scaffold") {
    VStack(alignment: .leading, spacing: 20) {
        Text("Short (should not scroll)").font(.caption).foregroundStyle(.secondary)
        SeamlessMarqueeText(
            text: "Short title",
            style: .body,
            fontWeight: .medium,
            color: .primary
        )
        .frame(width: 200)
        .border(Color.red.opacity(0.3))

        Text("Long (overflow, no scroll yet)").font(.caption).foregroundStyle(.secondary)
        SeamlessMarqueeText(
            text: "A very long title that definitely overflows its container width here",
            style: .body,
            fontWeight: .medium,
            color: .primary
        )
        .frame(width: 200)
        .border(Color.red.opacity(0.3))
    }
    .padding()
    .frame(width: 320, height: 160)
}
```

- [ ] Build to verify compilation:
```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug 2>&1 | grep -E "^.*error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `BUILD SUCCEEDED`, zero errors.

- [ ] In Xcode, open the Preview. Verify:
  - Short text renders correctly, left-aligned
  - Long text truncates with `…`, no animation
  - Heights look consistent between the two cases (no baseline jump)

- [ ] Commit:
```bash
git add myPlayer2/Views/Controls/SeamlessMarqueeText.swift
git commit -m "feat: add SeamlessMarqueeText static scaffold"
```

---

## Task 2: Add measurement and dual-copy layout

**Files:**
- Modify: `myPlayer2/Views/Controls/SeamlessMarqueeText.swift`

This task adds `@State` for width measurement, wires up the GeometryReader properly, and switches to the dual-copy `HStack` layout when text overflows. `offset` is always `0` here — the loop Task in Task 3 will actually set it.

**Measurement risk:** `textWidth` is derived from `NSString.size(withAttributes: [.font: nsFont])`. This assumes `nsFont` (constructed from `NSFont.systemFont(ofSize:weight:)`) matches exactly what SwiftUI's `Text` renders. Discrepancy can arise if SwiftUI applies optical sizing or other font variants not reflected in the `NSFont`. If a visible seam appears at the loop boundary (text copy 2 not perfectly adjacent to copy 1's end), replace `measureTextWidth()` with a hidden-`Text` measurement using `background(GeometryReader {...})`.

- [ ] Replace the entire `struct SeamlessMarqueeText: View` body (keep the extension initializers and Preview unchanged) with the following. The changes are: add `@State` properties, rewrite `body`, add `contentView`, add measurement functions, add stub loop functions.

```swift
struct SeamlessMarqueeText: View {

    enum Style: Equatable {
        case body
        case subheadline
        case caption
        case custom(fontSize: CGFloat)
    }

    let text: String
    let style: Style
    let fontWeight: Font.Weight
    let color: Color

    var gap: CGFloat = 40.0
    var speed: CGFloat = 40.0
    var pauseDuration: TimeInterval = 5.0
    var shouldAnimate: Bool = true
    var enablesContentTransition: Bool = false

    // MARK: - State

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0          // loop sets this in Task 3; always 0 here

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            contentView(width: width)
                .frame(width: width, alignment: .leading)
                .clipped()
                .onAppear { syncContainerWidth(width) }
                .onChange(of: width) { _, newWidth in syncContainerWidth(newWidth) }
        }
        .frame(height: lineHeight)
        .onChange(of: text)          { _, _ in refreshAndRestart() }
        .onChange(of: style)         { _, _ in refreshAndRestart() }
        .onChange(of: fontWeight)    { _, _ in refreshAndRestart() }
        .onChange(of: gap)           { _, _ in refreshAndRestart() }
        .onChange(of: speed)         { _, _ in refreshAndRestart() }
        .onChange(of: pauseDuration) { _, _ in refreshAndRestart() }
        .onChange(of: shouldAnimate) { _, newVal in
            if newVal { refreshAndRestart() } else { stopLoop() }
        }
        .onDisappear {
            stopLoop()
        }
    }

    // MARK: - Content view

    @ViewBuilder
    private func contentView(width: CGFloat) -> some View {
        let isMarquee = shouldAnimate && (textWidth - width) > 2.0
        if isMarquee {
            HStack(spacing: gap) {
                textLabel
                textLabel
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
        } else {
            textLabel
                .truncationMode(.tail)
        }
    }

    // MARK: - Text rendering (shared by both modes)

    @ViewBuilder
    private var textLabel: some View {
        let base = Text(text)
            .font(swiftUIFont)
            .fontWeight(fontWeight)
            .foregroundStyle(color)
            .lineLimit(1)
        if enablesContentTransition {
            base
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: text)
        } else {
            base
        }
    }

    // MARK: - Measurement

    private func syncContainerWidth(_ width: CGFloat) {
        guard abs(containerWidth - width) > 0.5 else { return }
        containerWidth = width
        refreshAndRestart()
    }

    private func measureTextWidth() {
        let attrs: [NSAttributedString.Key: Any] = [.font: nsFont]
        textWidth = ceil((text as NSString).size(withAttributes: attrs).width)
    }

    private func refreshAndRestart() {
        measureTextWidth()
        stopLoop()
        guard shouldAnimate, containerWidth > 0, textWidth > containerWidth + 2.0 else { return }
        startLoop()
    }

    // MARK: - Loop task stubs (implemented in Task 3)

    private func startLoop() { /* Task 3 */ }
    private func stopLoop()  { /* Task 3 */ }

    // MARK: - Font helpers

    private var swiftUIFont: Font {
        switch style {
        case .body:            return .body
        case .subheadline:     return .subheadline
        case .caption:         return .caption
        case .custom(let sz):  return .system(size: sz)
        }
    }

    var nsFont: NSFont {
        switch style {
        case .body:
            return NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                weight: nsWeight)
        case .subheadline:
            return NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: nsWeight)
        case .caption:
            return NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: nsWeight)
        case .custom(let sz):
            return NSFont.systemFont(ofSize: sz, weight: nsWeight)
        }
    }

    private var nsWeight: NSFont.Weight {
        switch fontWeight {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }

    var lineHeight: CGFloat {
        let f = nsFont
        return max(1, f.ascender - f.descender + f.leading)
    }
}
```

- [ ] Build:
```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug 2>&1 | grep -E "^.*error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `BUILD SUCCEEDED`.

- [ ] In Xcode Preview (or run in the app), verify:
  - Short text: single copy, left-aligned, truncated — same as Task 1
  - Long text: still static (offset=0), but the HStack dual-copy structure is now active; visually looks the same as Task 1 because `offset=0` and `.clipped()` hides the second copy

- [ ] Commit:
```bash
git add myPlayer2/Views/Controls/SeamlessMarqueeText.swift
git commit -m "feat: add measurement and dual-copy layout to SeamlessMarqueeText"
```

---

## Task 3: Implement the loop Task

**Files:**
- Modify: `myPlayer2/Views/Controls/SeamlessMarqueeText.swift`

- [ ] Add `@State private var loopTask: Task<Void, Never>? = nil` to the `// MARK: - State` section, immediately after `@State private var offset: CGFloat = 0`.

The State section should now read:
```swift
// MARK: - State

@State private var textWidth: CGFloat = 0
@State private var containerWidth: CGFloat = 0
@State private var offset: CGFloat = 0
@State private var loopTask: Task<Void, Never>? = nil
```

- [ ] Replace the stub `startLoop()` and `stopLoop()` under `// MARK: - Loop task stubs` with the full implementations:

```swift
// MARK: - Loop task

private func startLoop() {
    let distance = textWidth + gap                          // scroll distance per cycle
    let duration = Double(distance / max(1, speed))        // seconds for one scroll pass

    loopTask = Task { @MainActor in
        while !Task.isCancelled {

            // Phase 1 — Scroll: animate offset from 0 → -(textWidth + gap) linearly
            withAnimation(.linear(duration: duration)) {
                offset = -distance
            }

            // Wait for the animation to complete
            do { try await Task.sleep(for: .seconds(duration)) }
            catch { break }                                 // CancellationError → exit loop
            guard !Task.isCancelled else { break }

            // Phase 2 — Pause: hold at end position (copy 2 now occupies copy 1's slot)
            do { try await Task.sleep(for: .seconds(pauseDuration)) }
            catch { break }
            guard !Task.isCancelled else { break }

            // Phase 3 — Reset: set offset = 0 with no animation.
            // Invisible: at offset = -distance, copy 2 is visually identical to copy 1 at 0.
            resetOffsetImmediately()

            // Yield twice so SwiftUI renders the reset before the next withAnimation call.
            // Without this, the reset and the new animation may be batched into one
            // render pass, causing the animation to start mid-slide rather than from 0.
            await Task.yield()
            await Task.yield()
            guard !Task.isCancelled else { break }
        }
    }
}

private func stopLoop() {
    loopTask?.cancel()
    loopTask = nil
    resetOffsetImmediately()
}

private func resetOffsetImmediately() {
    var tx = Transaction()
    tx.disablesAnimations = true
    withTransaction(tx) { offset = 0 }
}
```

- [ ] Update the Preview at the bottom of the file to test animated behavior:

```swift
#Preview("SeamlessMarqueeText – Animated") {
    VStack(alignment: .leading, spacing: 20) {
        Group {
            Text("Short (no scroll)").font(.caption).foregroundStyle(.secondary)
            SeamlessMarqueeText(
                text: "Short title",
                style: .body, fontWeight: .medium, color: .primary
            )
            .frame(width: 200)
            .border(Color.red.opacity(0.3))
        }
        Group {
            Text("Long — should scroll seamlessly, pause 5s, loop").font(.caption).foregroundStyle(.secondary)
            SeamlessMarqueeText(
                text: "A very long title that definitely overflows its container width here",
                style: .body, fontWeight: .medium, color: .primary,
                speed: 30
            )
            .frame(width: 200)
            .border(Color.red.opacity(0.3))
        }
        Group {
            Text("shouldAnimate: false — must stay static").font(.caption).foregroundStyle(.secondary)
            SeamlessMarqueeText(
                text: "A very long title that definitely overflows but should not scroll at all",
                style: .body, fontWeight: .medium, color: .primary,
                shouldAnimate: false
            )
            .frame(width: 200)
            .border(Color.red.opacity(0.3))
        }
    }
    .padding()
    .frame(width: 320, height: 240)
}
```

- [ ] Build:
```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug 2>&1 | grep -E "^.*error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `BUILD SUCCEEDED`.

- [ ] Visually verify in Xcode Preview (enable live preview or run in app):
  - Long text scrolls smoothly without visible 30fps stepping
  - Right edge of copy 1 is immediately followed by copy 2's left edge (no gap or overlap at the join)
  - After scroll completes, pauses for ~5 seconds without movement
  - When pause ends, the reset is invisible — no flash, no jump
  - Next cycle starts from the beginning seamlessly
  - Short text row: completely static throughout
  - `shouldAnimate: false` row: static even though text overflows (no task, no animation)

- [ ] Commit:
```bash
git add myPlayer2/Views/Controls/SeamlessMarqueeText.swift
git commit -m "feat: implement seamless loop Task in SeamlessMarqueeText"
```

---

## Task 4: Migrate MiniPlayerView

**Files:**
- Modify: `myPlayer2/Views/MiniPlayer/MiniPlayerView.swift` (lines 72–88)

Both calls use the style-based initializer. `shouldAnimate` omitted → defaults to `true`.

- [ ] Replace the two `MarqueeText` calls inside the `if let track = playerVM.currentTrack` branch:

```swift
// BEFORE
MarqueeText(
    text: track.title,
    style: .subheadline,
    fontWeight: .medium,
    color: .primary,
    enablesContentTransition: true
)

MarqueeText(
    text: track.artist.isEmpty
        ? NSLocalizedString("library.unknown_artist", comment: "")
        : track.artist,
    style: .caption,
    fontWeight: .regular,
    color: .secondary,
    enablesContentTransition: true
)
```

```swift
// AFTER
SeamlessMarqueeText(
    text: track.title,
    style: .subheadline,
    fontWeight: .medium,
    color: .primary,
    enablesContentTransition: true
)

SeamlessMarqueeText(
    text: track.artist.isEmpty
        ? NSLocalizedString("library.unknown_artist", comment: "")
        : track.artist,
    style: .caption,
    fontWeight: .regular,
    color: .secondary,
    enablesContentTransition: true
)
```

- [ ] Build:
```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug 2>&1 | grep -E "^.*error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `BUILD SUCCEEDED`.

- [ ] Open "Mini Player" preview, verify title and artist display correctly for a track with a long name.

- [ ] Commit:
```bash
git add myPlayer2/Views/MiniPlayer/MiniPlayerView.swift
git commit -m "feat: migrate MiniPlayerView to SeamlessMarqueeText"
```

---

## Task 5: Migrate FullscreenMiniPlayerView

**Files:**
- Modify: `myPlayer2/Views/Fullscreen/FullscreenMiniPlayerView.swift` (lines 131–148)

Both calls use the `fontSize:` convenience initializer. `shouldAnimate` omitted → defaults to `true`.

- [ ] Replace the two `MarqueeText` calls inside `trackInfoView`:

```swift
// BEFORE
MarqueeText(
    text: track.title,
    fontSize: titleFontSize,
    fontWeight: .semibold,
    color: lyricsDynamicPrimaryColor,
    enablesContentTransition: true
)

MarqueeText(
    text: track.artist.isEmpty
        ? NSLocalizedString("library.unknown_artist", comment: "")
        : track.artist,
    fontSize: artistFontSize,
    fontWeight: .medium,
    color: lyricsDynamicSecondaryColor,
    enablesContentTransition: true
)
```

```swift
// AFTER
SeamlessMarqueeText(
    text: track.title,
    fontSize: titleFontSize,
    fontWeight: .semibold,
    color: lyricsDynamicPrimaryColor,
    enablesContentTransition: true
)

SeamlessMarqueeText(
    text: track.artist.isEmpty
        ? NSLocalizedString("library.unknown_artist", comment: "")
        : track.artist,
    fontSize: artistFontSize,
    fontWeight: .medium,
    color: lyricsDynamicSecondaryColor,
    enablesContentTransition: true
)
```

- [ ] Build:
```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug 2>&1 | grep -E "^.*error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `BUILD SUCCEEDED`.

- [ ] Commit:
```bash
git add myPlayer2/Views/Fullscreen/FullscreenMiniPlayerView.swift
git commit -m "feat: migrate FullscreenMiniPlayerView to SeamlessMarqueeText"
```

---

## Task 6: Migrate TrackRowView

**Files:**
- Modify: `myPlayer2/Views/Library/TrackRowView.swift` (lines 84–99)

`shouldAnimate: isPlaying || isHovering` is preserved exactly. `isHovering` state and `onHover` handler are **not touched**. When `shouldAnimate` goes false (hover exit), `SeamlessMarqueeText` cancels its task and resets offset immediately via `stopLoop()`.

- [ ] Replace the two `MarqueeText` calls:

```swift
// BEFORE
MarqueeText(
    text: model.title,
    style: .body,
    fontWeight: isPlaying ? .semibold : .regular,
    color: textPrimaryColor,
    shouldAnimate: isPlaying || isHovering
)
.frame(maxWidth: .infinity, alignment: .leading)

MarqueeText(
    text: artistText,
    style: .subheadline,
    fontWeight: .regular,
    color: textSecondaryColor,
    shouldAnimate: isPlaying || isHovering
)
.frame(width: 220, alignment: .leading)
```

```swift
// AFTER
SeamlessMarqueeText(
    text: model.title,
    style: .body,
    fontWeight: isPlaying ? .semibold : .regular,
    color: textPrimaryColor,
    shouldAnimate: isPlaying || isHovering
)
.frame(maxWidth: .infinity, alignment: .leading)

SeamlessMarqueeText(
    text: artistText,
    style: .subheadline,
    fontWeight: .regular,
    color: textSecondaryColor,
    shouldAnimate: isPlaying || isHovering
)
.frame(width: 220, alignment: .leading)
```

- [ ] Build:
```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug 2>&1 | grep -E "^.*error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `BUILD SUCCEEDED`.

- [ ] Verify the following behaviors in-app (library view):
  - Row not hovered, not playing → title and artist are static, truncated with `…`
  - Row hovered with long text → scrolling starts; smooth, seamless loop
  - Mouse leaves row mid-scroll → scrolling stops immediately, text snaps back to start
  - Mouse re-enters → scrolling restarts from position 0
  - Currently playing row with long title → scrolls regardless of hover

- [ ] Commit:
```bash
git add myPlayer2/Views/Library/TrackRowView.swift
git commit -m "feat: migrate TrackRowView to SeamlessMarqueeText (preserves isPlaying||isHovering)"
```

---

## Task 7: Delete MarqueeText.swift

**Files:**
- Delete: `myPlayer2/Views/Controls/MarqueeText.swift`

- [ ] Confirm no remaining references to `MarqueeText`:
```bash
grep -r "MarqueeText" myPlayer2/ --include="*.swift"
```
Expected: zero output. If any results appear, go back and fix them before proceeding.

- [ ] Delete the file:
```bash
rm myPlayer2/Views/Controls/MarqueeText.swift
```
Then in Xcode: right-click the file in the navigator → Delete → "Move to Trash" (or use "Remove Reference" if you deleted via terminal).

- [ ] Build to confirm no dangling symbols:
```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug 2>&1 | grep -E "^.*error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `BUILD SUCCEEDED`.

- [ ] Commit:
```bash
git add -A
git commit -m "chore: delete MarqueeText (fully replaced by SeamlessMarqueeText)"
```

---

## Risk Points and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `NSString.size` textWidth ≠ SwiftUI `Text` rendered width (visible seam at loop boundary) | Low–Medium | Monitor in-app with a very long title; if seam appears, replace `measureTextWidth()` with a hidden `Text` behind `background(GeometryReader { g in Color.clear.onAppear { textWidth = g.size.width } })` |
| Rapid hover in/out (TrackRowView) leaves stale loop task | Low | `stopLoop()` always calls `loopTask?.cancel()` before any `startLoop()`; at most one task is ever live |
| `Task.yield() × 2` not sufficient to separate reset from next animation (reset + animation coalesce) | Very Low | If observed: add `try? await Task.sleep(for: .milliseconds(8))` after the two yields |
| `Task.sleep` timing drift vs animation duration | Very Low | Sleep can only overshoot (never undershoot), so animation has always completed when pause begins; <10ms drift is imperceptible |
| Window resize mid-scroll causes jump or duplicate task | Low | `onChange(of: width)` → `syncContainerWidth` → `refreshAndRestart()` cancels old task before starting new one |
| `fontWeight` change causes mid-animation stale measurement | Low | `onChange(of: fontWeight)` triggers `refreshAndRestart()` → cancel + remeasure + restart |

---

## Acceptance Criteria

- [ ] Long title/artist in MiniPlayer scrolls smoothly (no visible 30fps stepping)
- [ ] Right edge of copy 1 is immediately followed by copy 2's left edge (no visible jump at loop boundary)
- [ ] Pause of ~5 seconds after each full scroll
- [ ] Reset at end of pause is invisible to the user
- [ ] Short text: completely static, zero animation resources consumed
- [ ] `shouldAnimate: false`: static truncated display, no task created
- [ ] `shouldAnimate` false → true: starts scrolling cleanly from position 0
- [ ] TrackRowView: hover out mid-scroll → stops and resets to 0 immediately
- [ ] TrackRowView: re-hover → scrolls from position 0
- [ ] Track change mid-scroll: resets and restarts with new text
- [ ] Window resize mid-scroll: resets and restarts with correct container width
- [ ] `FullscreenMiniPlayerView`: same behavior as MiniPlayer, using scaled font sizes
