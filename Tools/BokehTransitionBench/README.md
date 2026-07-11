# BokehTransitionBench

This standalone tool benchmarks the player's trimmed `basicBokehGather` Metal
kernel against synthetic highlight dots. It is intentionally outside the app
target: command-buffer waits and texture readback are acceptable here, but are
not used by the fullscreen renderer.

From the repository root:

```bash
mkdir -p /tmp/BokehTransitionBench
xcrun -sdk macosx metal -c kmgccc_player/Rendering/BokehTransition/BokehTransitionShader.metal \
  -o /tmp/BokehTransitionBench/BokehTransitionShader.air
xcrun -sdk macosx metallib /tmp/BokehTransitionBench/BokehTransitionShader.air \
  -o /tmp/BokehTransitionBench/BokehTransitionShader.metallib
xcrun swiftc Tools/BokehTransitionBench/main.swift -framework Foundation -framework Metal \
  -o /tmp/BokehTransitionBench/BokehTransitionBench
/tmp/BokehTransitionBench/BokehTransitionBench \
  /tmp/BokehTransitionBench/BokehTransitionShader.metallib /tmp/BokehTransitionBench/output
```

The tool prints 128/192/256 sample sweeps using the app's actual linear
`rgba16Float` gather target. Visual export belongs after the sRGB present pass;
the benchmark deliberately does not reinterpret half-float working pixels as a
display image.
