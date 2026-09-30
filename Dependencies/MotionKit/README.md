# MotionKit

MotionKit is a small macOS Swift package for semantic spring motion. It wraps
Apple's SwiftUI `Spring`/`Animation`, Core Animation `CASpringAnimation`, and
`Spring.value`/`velocity` evaluation without introducing a custom solver.

## Basic use

```swift
import MotionKit

struct ExampleView: View {
    @State private var isExpanded = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .frame(height: isExpanded ? 160 : 44)
            .motionAnimation(.layout, value: isExpanded)
    }
}
```

At an AppKit hosting boundary, inject the standard vocabulary and an
overridable policy once so descendants share the same configuration:

```swift
let rootView = ExampleView()
    .motionEnvironment()
```

The default semantic set is available through `MotionTokens.standard`. A
subtree can override one token without creating a second animation vocabulary:

```swift
let tokens = MotionTokens.standard.replacing(
    .control,
    with: MotionSpec(duration: 0.26, bounce: 0.04)
)

content.motionTokens(tokens)
```

For a multi-phase choreography that needs a local phase duration, derive the
phase from the semantic token instead of constructing a second curve. The
phase keeps the token's bounce and blend behavior, and follows any duration
override applied by the current surface:

```swift
let fadeSpec = tokens.phaseSpec(
    for: .contentReplacement,
    duration: 0.32,
    bounce: 0
)
let fadeAnimation = policy.animation(for: fadeSpec)
```

Use `MotionPolicy.reduced` for reduced motion and `.disabled` when a state must
arrive immediately. For non-View owners that receive the accessibility flag at
their boundary, use `MotionPolicy.system(accessibilityReduceMotion:)` so the
system mapping stays consistent:

```swift
let policy = MotionPolicy.system(
    accessibilityReduceMotion: accessibilityReduceMotion
)
```

`motionAnimation` also respects the system accessibility reduce-motion setting;
an explicit `.disabled` policy remains disabled.

For non-View code that still needs the system setting, resolve the policy at the
same boundary instead of duplicating the conditional:

```swift
let animation = MotionPolicy.full.resolvedAnimation(
    for: MotionTokens.standard[.navigation],
    accessibilityReduceMotion: accessibilityReduceMotion
)
```

For Core Animation, use the same `MotionSpec`:

```swift
let animation = MotionTokens.standard[.control].coreAnimation(
    keyPath: "position.x"
)
```

For a layer-backed AppKit surface, use `MotionLayerAnimator` so the model
layer is updated before the spring is installed and disabled motion snaps
without leaving a stale animation:

```swift
let delay = MotionLayerAnimator.animate(
    layer: panel.contentView!.layer!,
    keyPath: "opacity",
    fromValue: 0,
    toValue: 1,
    spec: MotionTokens.standard[.contentReplacement],
    policy: policy,
    animationKey: "motionKit.panel.opacity"
)
```

The returned delay is a visual settling window only. It can coordinate cleanup
of a transient layer, but must not gate the underlying business operation.

For gesture release, keep the token as the base curve and pass the measured
velocity at the boundary:

```swift
let initialVelocity = MotionSpec.normalizedInitialVelocity(
    from: currentPosition,
    to: targetPosition,
    velocity: releaseVelocity
)
let animation = MotionPolicy.full.animation(
    for: MotionTokens.standard[.gestureSettle],
    initialVelocity: initialVelocity
)
```

For pointer-driven gestures, pass the normalized value through
`MotionSpec.clampedInitialVelocity` before building the animation.

For a display-link-driven property that can be retargeted while moving, keep
the state in `MotionRetargetState` instead of rebuilding a second spring model:

```swift
var state = MotionRetargetState(value: currentValue, spec: token)
state.retarget(to: targetValue, at: timestamp)
let frame = state.advance(to: timestamp)
```

Call `snap(to:)` for a disabled policy or when the host leaves the window. The
type carries the current value and velocity into the next target, so rapid
reverse gestures do not jump back to the old model value.

For transient visual cleanup, such as removing a drag proxy after its spring
settles, use `MotionPolicy.visualCompletionDelay(for:initialVelocity:)`. A
disabled policy returns zero. This helper must not gate business-operation
completion; use an explicit state transition or completion callback for that.

For low-frequency diagnostics, `MotionTokens.diagnostic(for:policy:backend:)`
returns a value containing the semantic token, resolved policy, backend, and
whether a dynamic initial velocity was supplied. MotionKit does not log these
values automatically.

Perceptual specs use Apple's `Spring(duration:bounce:)` for the base curve.
When a non-zero release velocity is supplied, MotionKit uses Apple's
`Animation.interpolatingSpring(_:initialVelocity:)` adapter so the velocity is
not discarded; the zero-velocity path retains the configured blend duration.

Continuous time-driven animation, display-link followers, marquee loops,
audio meters, keyframe choreography, and lyrics rendering should keep their
own clocks or state machines instead of being converted to implicit springs.
They can still use `MotionSpringEvaluator` and a semantic token when a
display-link-driven retarget is the correct backend.

The player’s capsule spectrum host keeps its closed-form follower as the
production backend. A Debug build can opt into the Apple evaluator for an A/B
trace without changing the default path:

```sh
MOTIONKIT_CAPSULE_SPECTRUM_BACKEND=appleSpringEvaluator
```

The override is read when the host is configured and is intentionally absent
from release behavior. Keep the closed-form backend unless a real playback
trace shows equivalent or better hitch, latency, CPU/GPU, and energy results.

## Demo

Build the standalone demo from the package root with:

```sh
swift build --product MotionKitDemo
swift run MotionKitDemo
```

The demo exercises semantic token overrides, full/reduced/disabled policy,
continuous retargeting, and gesture release velocity without importing any
player-specific type.
