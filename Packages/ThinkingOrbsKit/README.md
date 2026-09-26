# ThinkingOrbsKit

Dotted thought-orb loading indicators: the SwiftUI edition of
[thinking-orbs](https://libraries.dev) 0.3.2. Nine hand-tuned states, three
sizes (`.px64`, `.px32`, `.px20`), automatic dark/light ink, tints, density
and dot-size multipliers, raw engine options and custom geometry.
`TimelineView(.animation)` drives the clock and `Canvas` draws; there is no
Metal.

iOS 15 / macOS 12. No dependencies.

```swift
import ThinkingOrbsKit

ThinkingOrb(state: .searching, size: .px64)
ThinkingOrb(state: .composing, size: .px32, speed: 0.7, color: .amber, opts: ["wobMul": 0.5])
```

## This edition

- Brought up to 0.3.2: `.px32` (regenerated spec), plus `color:`, `dots:`,
  `dotSize:`, `opts:` and `frame:` (custom geometry with `OrbToolkit`).
- The held `shape` in `.shaping` is ported.
- Reduce Motion draws the web's instant (t = 0.6, raw).
- `paused` holds the current frame, as on the web.
- A negative `speed` is floored at 0 (it indexed out of range in
  `.shaping`).

## Verification

The geometry is the web engine's math transcribed to Swift, so golden
vectors guard it:
- `OrbGoldenTests`: 108 cases (9 states × 3 sizes × 4 times), 90,664 values
  within 1e-4.
- `OrbTuningTests`: the tuned options (dots, dotSize, opts, held shape)
  frame for frame, plus the tint ramp.
- `OrbCustomFrameTests` builds the documented `frame:` examples against
  the public API.
- `AccessibilityTests` checks the VoiceOver labels.

`OrbGoldenTests` compares dots as a multiset plus a z-order check. Dots on
the exact view plane carry ±1e-17 depth noise whose sign depends on libm,
so JavaScript and Swift may order them differently; the pictures are
identical.

## Tests

```bash
xcodebuild test -scheme ThinkingOrbsKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```


`OrbPerformanceTests` runs only in Release (the heaviest state is under
0.5 % of a 60 fps frame). `./snapshot.sh [dir]` writes PNGs of every state,
size, theme and frozen instant through `ImageRenderer` (`swift test`, no
Simulator).

The full reference is the libraries-dev skill's
`references/02-thinking-orbs.md`.
