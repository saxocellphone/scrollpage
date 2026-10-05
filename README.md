# Scrollpage

Your hand is the trackpad. Scrollpage is a macOS menu bar app that watches one
hand through the webcam (Apple Vision hand pose) and moves the pointer, clicks
and scrolls system-wide, with the motion model of an Apple trackpad: relative
pointer motion with acceleration, tap-to-click, and momentum scrolling.

No keyboard is involved at all: no hotkeys, no modifier combos, no synthesized
key presses.

## Gestures

| Do this | Get this |
| --- | --- |
| Pinch (thumb + index) and move | Move the pointer. Slow is precise, fast crosses the screen. |
| Quick pinch without moving | Click. Two quick pinches double-click, three triple-click. |
| Pinch, hold still ~0.6 s, then move | Drag (mouse button held until you let go). |
| Flick an open hand up/down/left/right | Momentum scroll, like a two-finger fling. |
| Pinch while the page glides | Catch the glide (stops it at once). |
| Open hand, or hand out of view | Finger lifted: nothing moves. |

The pointer is relative, like a trackpad: letting go of the pinch is lifting
your finger, so you can "clutch" (release, move the hand back, pinch again) to
keep going in one direction.

### Why a quick pinch for click

Pinch-and-move is the pointing gesture, so click had to be something that never
fires by accident while pointing and never moves the pointer. A trackpad solves
the same problem with tap-to-click: a touch that lifts quickly without sliding
is a click, a touch that slides is pointing. Scrollpage does exactly that with
the pinch:

- A pinch that releases within 0.35 s and stays within a small slop (about a
  tenth of a hand length) is a click. Until the slop is exceeded the pointer
  doesn't move at all, so the click lands exactly where you aimed.
- The pointer also freezes as soon as the fingers start to open, which removes
  the jitter of letting go (the main reason webcam clicks miss).
- Anything longer or with movement is pointing, so pointing never clicks.

Other options were worse: a second hand sign (for example a middle-finger pinch)
is hard to discover and gets confused with the index pinch at webcam
resolution; dwell-to-click fires while you are reading; "pinch harder" has no
reliable signal from a 2D camera.

### Why a flick for scroll

Scrolling is a motion, not a pose. A quick flick of the open hand is recognized
from its speed profile (fast, short, then a stop) and its peak velocity becomes
the fling velocity, which then decays like a trackpad glide (v0 · e^(−t/325 ms)).
Slow hand movements, hands entering the frame, the hand returning after a
flick, and the motion right after a pinch are all ignored, so moving your hand
around doesn't scroll.

## How it feels like a trackpad

- **Acceleration.** The hand's speed (measured over ~80 ms) picks a gain from a
  macOS-style curve that rises smoothly in log-speed: ~165 pt per hand length
  when slow, about a screen width per hand length when fast, and zero below a
  rest speed so a still hand never drifts.
- **Jitter.** A One Euro filter smooths the hand position (strong at rest, light
  when moving). Motion is measured in hand units (wrist to middle knuckle), so
  it feels the same near or far from the camera.
- **Rendering.** Gestures move a target; a 120 Hz driver eases the real pointer
  toward it (τ ≈ 22 ms), so 30 fps camera frames still give smooth motion.
- **Scroll events** are posted like a real trackpad: pixel-precise, continuous,
  with scroll phases (began/ended) followed by momentum phases, so apps that
  care about momentum (Safari, Chrome, AppKit scroll views) treat them natively.
- **Feedback.** A ring follows the pointer while the pinch is down, fills while
  dragging and pulses on click. A small status pill at the top of the screen
  shows what changed and fades after 2 s.

## Build and run

Requirements: macOS 14 or later, Xcode command line tools (Swift 5.9+), a
webcam.

```bash
make build      # swift build -c release, then build/Scrollpage.app (ad-hoc signed)
make run        # build and open the app
make test       # unit tests for the gesture engine
make install    # copy to /Applications (INSTALL_DIR=... to change)
make diagnose   # headless camera + engine report (DIAGNOSE_SECONDS=15)
make clean
```

Scrollpage lives in the menu bar (hand icon). The first launch opens the
camera preview and tutorial.

## Permissions

- **Camera**: to see your hand. Video is processed on the Mac and never stored.
- **Accessibility**: to move the pointer, click and scroll. Scrollpage shows an
  "Allow Accessibility" pill and a banner until it is granted.

The app is **ad-hoc signed** by default. macOS ties privacy grants to the code
signature, so **every rebuild invalidates the Accessibility (and possibly
Camera) grant**: open System Settings > Privacy & Security > Accessibility,
remove Scrollpage with the minus button, and add the new build again. To avoid
this, sign with a stable identity:

```bash
make build SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

## Settings

The menu bar popover has an on/off switch and three settings, nothing else:

- **Tracking speed**: mostly changes how far fast movements go, like the macOS
  slider.
- **Scrolling speed**: scales the fling velocity.
- **Natural scrolling**: on means hand up moves the content up, like a
  trackpad with natural scrolling. Defaults to the system setting.

Scrollpage pauses the camera while the screen sleeps or the user session is
switched out, and turns it off entirely when switched off. The camera picker is
in the preview window.

## Diagnostics

```bash
build/Scrollpage.app/Contents/MacOS/Scrollpage --diagnose 15 --record session.jsonl
build/Scrollpage.app/Contents/MacOS/Scrollpage --diagnose --replay session.jsonl
```

`--diagnose` runs the camera, Vision and the real gesture engine without posting
any events, then prints frame rate, Vision time, capture-to-gesture latency,
hand detection rate, pinch ratio range, palm jitter, how far a still hand would
drift the pointer if pinched, and which gestures fired. `--record` saves every
frame's joints; `--replay` runs the engine over a recording, which is the way to
tune thresholds against real hands. (When run from a terminal, macOS asks for
camera access on behalf of the terminal app.)

## Project layout

- `Sources/ScrollpageCore`: the pure, tested motion model: `HandSample`,
  `OneEuroFilter2D`, `PointerAcceleration`, `PinchDetector`, `FlickDetector`,
  `MomentumScroller`, and `GestureEngine`, which turns hand samples into
  trackpad events.
- `Sources/Scrollpage`: the app: camera + Vision pipeline, CGEvent input
  driver, menu bar popover, status pill, touch ring, onboarding, diagnostics.
- `Tests/ScrollpageCoreTests`: XCTest suite driven by a synthetic hand with
  webcam-like noise (drift, tap, double tap, drag, hand loss, flicks and the
  false-flick cases, momentum, filter and curve properties).

## Credits

Scrollpage started as a fork of [Gstrl](https://github.com/TomYang-TZ/Gstrl) by
Tom Yang (MIT). The Gstrl feature set (keyboard gestures, voice commands, agent
integration) was removed and the gesture engine was rewritten. Ideas kept from
Gstrl: the AVFoundation + Vision capture loop that drops late frames instead of
queuing them, and driving the pointer from the palm center (mean of the
knuckles) during a pinch, which stays put while the fingertips close.

The motion model follows the One Euro filter (Casiez, Roussel and Vogel, CHI
2012) and the usual iOS/macOS kinetic scrolling constant.

## License

MIT. See [LICENSE](LICENSE); Tom Yang's original copyright notice is kept.
