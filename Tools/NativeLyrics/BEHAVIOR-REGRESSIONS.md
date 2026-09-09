# Native lyrics behavior corrections — 2026-09-06

This supersedes the Demo's earlier center-out click cascade and trailing highlight smoothing. Production WebView code and the AMLL submodule are unchanged.

## Root causes and contracts

| Symptom | Cause | Native contract |
|---|---|---|
| Historical rows stay sharp | `highlighted` is a retained timeline set, not the live singing set | Parallel foreground rows remain clear/highlighted until the whole group ends; ordinary sequential rows still fade |
| Blur jumps / appears absent | Reassigning the same mutable CI filter could retain the compositor's old radius | Publish a copied filter state on every changed frame; tween radius over 450 ms, default 3–6 pt |
| Hover behavior differs by playback state | Pointer state was not reconciled reliably and paused display links could stop before a deferred transition | Pointer inside and manual browsing clear all rows; the default starts blur immediately on pointer exit, while hosts can opt into a delay; pending deadlines keep paused updates alive |
| Click causes overlap | Delay was proportional to distance from clicked row | Cascade from first visible row down at 55 ms per row, including rows above the clicked row; preserve each scheduled start while layout targets change |
| Slider seek produces scattered motion | Every discontinuity used the same spring cascade | `synchronize(... seek: true, motion: .immediate)` snaps the entire stack and cancels queued springs; clicks explicitly request `.cascade` |
| English/BG highlight stalls or jumps | Untimed spaces inherited the whole paragraph range; sorting mask points by time reordered spatial positions | Whitespace occupies adjacent word gaps; mask boundaries retain text order and clamp backwards times |
| 3 Strikes first-line irregularity | The local TTML's `got` starts at 0.831 s after `I` at 1.703–1.831 s | Renderer tolerates this backwards boundary without editing library data or reordering words |
| Highlight smoothing lags | Exponential filter trailed an already predicted clock; forward glide stopped as soon as it led | Apply every media sample immediately; only bounded forward anticipation through authored gaps remains; paused/seek position stays exact |
| Background floats around main | Independent slide, scale and discontinuous flow-height changes | One non-overshooting reveal tween owns flow height and BG scale; BG edge is attached to main's transformed edge with a fixed gap |
| Emphasis/glow remain after exit | Media sample froze at the emphasis peak | Multiply emphasis displacement, scale delta and glow by the finite exit lifetime; zero lifetime restores identity |
| Exit highlight never finishes | Catch-up used a visually truncated group end | Use actual word-mask end, including BG words; fork's 16 ms threshold and 120–280 ms catch-up duration; native default exit fade is 280 ms and begins immediately |

The forward gap anticipation is an intentional native product extension. The fork's `lyric-line.ts` explicitly emits static mask keyframes during authored gaps and avoids additional easing to protect word timing. It is not accurate to describe perpetual movement through every authored gap as exact upstream behavior. The native anticipation is bounded (default up to 1.44 pt and 8% of the next segment), and never trails the authored sweep.

## Host API

`LyricsConfiguration` remains the single configuration value. `motion` exposes blur radius/cap/transition, pointer exit delay, click stagger, BG reveal duration, resize spring, exit fade, catch-up bounds and highlight anticipation. The top-level configuration also exposes interlude-dot scale. Existing typography, palette, alignment, timing, spring, quality and surface controls remain available. These are renderer-owned semantics, not host mutations of internal layers.

```swift
var configuration = LyricsConfiguration()
configuration.motion.pointerExitDelay = 0 // blur begins immediately on exit
configuration.motion.blurTransition = 0.45
configuration.motion.resizeSpring = SpringParameters(mass: 1, damping: 22, stiffness: 120, soft: true)
configuration.interludeDotScale = 1
configuration.channelBlend = .init(
    inactive: .normal,
    current: .normal,
    highlight: .plusLighter
)
lyrics.configuration = configuration
lyrics.synchronize(time: time, playing: playing, seek: true, motion: .immediate)
```

All-nil channel modes preserve the surface preset. Setting any channel enables explicit ink composition, with remaining nil channels using normal. The base ink mode switches between inactive/current; the highlight mode is composed into the glyph's premultiplied ink gradient before the single glyph alpha mask, so it never blends with the window or cover backdrop. Inactive/current modes may still select a host compositor for the complete lyric surface. Filter objects are cached by mode. Motion and channel-only configuration changes do not reshape text. The Demo exposes all three blend selectors plus a colored backdrop test that makes the internal-only highlight path observable. A lyric click requests seek and starts playback; slider/back/forward retain playback state and use immediate motion.

## Verification

`BehaviorRegressionTests` covers blur transition and pointer deadline, top-to-bottom click startup, scrub cancellation, malformed/whitespace mask continuity, forward gap anticipation, catch-up past truncated group end, and emphasis teardown with independent blend channels. Existing decoder, timing, layout, cache and spring tests remain required.

The completed regression run passes 69 tests. A background reveal test also checks continuous entry/exit height and bounded scale with no independent slide. Pointer enter/move/exit events are handled by an always-active tracking area; pointer exit starts the blur tween immediately by default. Blur exempts every currently hot or retained parallel foreground row, while interlude and ordinary historical rows still blur. Resize reflow uses a critically damped, zero-initial-velocity track so a newly wrapped half-line follows the new geometry without focus-change bounce. The three interlude dots use a centered transform anchor and expose their diameter through `interludeDotScale`. Manual browsing remains suspended while the pointer is inside; after pointer exit it resumes at the profile timeout (five seconds for the current-player profile), using the same ordered spring cascade rather than a hard reset.

Live window checks cover visible blur on non-current rows, sharp current text, library selection of 3 Strikes, playback, and clear manual browsing. Screenshot observations do not establish a numerical visual-parity score or a complete performance benchmark. Complex overlapping voices, different skins/backdrops and long resize/seek sequences remain part of the broader parity acceptance matrix.
