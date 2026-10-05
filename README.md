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
| Raise a palm, all five fingers spread, hold still ~1 s | Turn gestures off, or back on. |

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

### Turning gestures off and on

When you want to use your hands for something else, hold one up facing the
camera with all five fingers spread (thumb out too), and keep it still for
about a second. The status pill says **Gestures off**: nothing moves, clicks or
scrolls, and Scrollpage only watches for that same pose. Hold it up again for
**Gestures on**. After 0.3 s of holding, the pill shows "Hold to turn off" (or
on) with a ring filling up, so you can see it coming and cancel by moving or
relaxing the hand. Turning off mid-drag releases the button, and a glide in
progress stops.

Why this pose and these rules:

- **Nothing else uses it, and ordinary hands don't make it.** In three recorded
  sessions of ordinary use (535 hand frames of pointing, clicking, flicking and
  resting), not one frame met all four conditions: four fingers extended, thumb
  out, fingers spread (index tip to little tip at least 0.75 hand lengths) and
  the hand upright within 35°. Each of the first three conditions matters on its
  own: without the spread 16 frames would match, without "upright" 4, without
  four extended fingers 25. A relaxed open hand (fingers together) still just
  means "finger lifted".
- **Still, for a second.** The hold restarts if the hand moves faster than 0.4
  hand lengths per second or wanders more than 0.2. Flicks start at 1.5 and
  peak above 3.5, so a flick through the pose never toggles, and holding still
  never flicks.
- **Once per hold.** After a toggle the hand must leave the pose (or the frame)
  for 0.3 s before the next one, and two toggles are at least 1.5 s apart. After
  a toggle, flicks wait until the hand has left the pose for 0.4 s and slowed
  down, so lowering your hand doesn't scroll.
- **Limits.** A 2D pose can't reliably tell the palm from the back of the hand,
  so a spread hand facing either way works. The thresholds come from hand
  proportions and the synthetic tests; there is no recording of real raised
  palms yet, so check yours with `--diagnose --record` and `--replay` (the
  "Raised palm" line).

The gesture and the menu switch are the same on/off state: after the gesture
the switch shows off, and the switch can turn gestures back on. The difference
is the camera. Off by gesture, it keeps running, because that is how it sees
your palm to turn back on. Off from the menu, it stops, so only the menu can
turn Scrollpage back on. Off by gesture is not remembered across launches.

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
  a short gesture (began, changed on the next few frames, ended) followed by
  momentum phases, so apps that care about momentum (Safari, Chrome, AppKit
  scroll views) treat them natively. AppKit ignores a gesture with no changed
  events, and the momentum after it.
- **Feedback.** A thin ring centered on the pointer's hotspot while the pinch
  is down: it fades in when the finger lands, contracts briefly on click, keeps
  a faint fill while dragging and fades out on lift (opacity only with Reduce
  Motion, solid with Increase Contrast). A small status pill at the top of the screen
  shows what changed and fades after 2 s.

## Build and run

Requirements: macOS 14 or later, Xcode command line tools (Swift 5.9+), a
webcam.

```bash
make build      # swift build -c release, then build/Scrollpage.app (locally signed, see below)
make run        # build and open the app
make test       # unit tests for the gesture engine
make install    # copy to /Applications (INSTALL_DIR=... to change)
make diagnose   # headless camera + engine report (DIAGNOSE_SECONDS=15)
make check-permissions  # what macOS privacy checks see for build/Scrollpage.app
make test-scroll        # the app posts one fling at the pointer (VY=-2000)
make clean
```

Scrollpage lives in the menu bar (hand icon). The first launch opens the
camera preview and tutorial.

## CI builds

Every push runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml) on a
macOS runner: `swift build`, `swift test`, then `make build`, and uploads an
ad-hoc signed `Scrollpage-<sha>.zip` artifact (kept 14 days; `v*` tags also
publish a GitHub Release). To install the newest green build of the current
branch (needs the GitHub CLI):

```bash
scripts/install-latest.sh                      # to ~/Applications, unquarantined, then opens it
scripts/install-latest.sh --reset-permissions  # also reset the Accessibility grant
```

See [docs/ci.md](docs/ci.md) for options, manual installs, releases and
Gatekeeper notes.

## Permissions

- **Camera**: to see your hand. Video is processed on the Mac and never stored.
- **Accessibility**: to move the pointer, click and scroll. Scrollpage shows an
  "Allow Accessibility" pill and a banner until it is granted.

macOS ties privacy grants to the app's designated requirement. An ad hoc
signature's requirement is its cdhash, so with ad hoc signing **every rebuild
silently loses the Accessibility grant**: System Settings still shows
Scrollpage switched on, but the new binary is not trusted and every pointer,
click and scroll event is dropped.

So `make build` signs with **Scrollpage Local Signing**, a self-signed identity
that `scripts/local-signing.sh` creates on first use in a dedicated keychain
under this clone's `.git` (shared by its worktrees, never committed; the login
keychain and trust settings are not touched). The requirement becomes
`identifier "com.saxocellphone.scrollpage" and certificate leaf = H"…"`, which
stays the same across rebuilds, so the grant only has to be given once per
clone. Other options:

```bash
make build SIGN_IDENTITY=-   # ad hoc (what CI uses)
make build SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

Copies with different signatures (a CI download, an ad hoc build, another
clone) each need their own grant. If Scrollpage shows "Allow Accessibility"
while System Settings shows it switched on, click Allow: Scrollpage removes its
stale entry (`tccutil reset Accessibility com.saxocellphone.scrollpage`) so the
system prompt can add the running copy, then switch it on. `make
check-permissions` prints what the running build's signature and trust are.

## Settings

The menu bar popover has an on/off switch and three settings, nothing else:

- **Tracking speed**: mostly changes how far fast movements go, like the macOS
  slider.
- **Scrolling speed**: scales the fling velocity.
- **Natural scrolling**: on means hand up moves the content up, like a
  trackpad with natural scrolling. Defaults to the system setting.

Scrollpage pauses the camera while the screen sleeps or the user session is
switched out, and turns it off entirely when switched off from the menu (not
when turned off by the raised-palm gesture, see above). The camera picker is
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

`--ring-demo [seconds]` cycles the touch ring through touch, click, drag and
lift at the pointer; `--render-ring states.png [single.png [pills.png]]`
renders the ring states, and optionally the toggle's status pills, offscreen
over light and dark backgrounds.

```bash
make check-permissions        # or: open -W -n --stdout "$(tty)" build/Scrollpage.app --args --check-permissions
make test-scroll VY=-2000     # content velocity in pt/s, y-down; --vx and --at x,y on the CLI
log stream --predicate 'subsystem == "com.saxocellphone.scrollpage"'
```

`--check-permissions` prints `AXIsProcessTrusted`, `CGPreflightPostEventAccess`,
the cdhash and the designated requirement. `--test-scroll` posts one fling
through the real input driver, exactly as a detected flick would. Both must be
launched through `open` to test the app's own grant; run directly from a
terminal, macOS checks the terminal's grant instead. The log has permission
changes, every stroke the flick detector judged (and why it was rejected),
flings and how many scroll events each posted.

## Project layout

- `Sources/ScrollpageCore`: the pure, tested motion model: `HandSample`,
  `OneEuroFilter2D`, `PointerAcceleration`, `PinchDetector`, `FlickDetector`,
  `ToggleGestureDetector`, `MomentumScroller`, and `GestureEngine`, which turns
  hand samples into trackpad events.
- `Sources/Scrollpage`: the app: camera + Vision pipeline, CGEvent input
  driver, menu bar popover, status pill, touch ring, onboarding, diagnostics.
- `Tests/ScrollpageCoreTests`: XCTest suite driven by a synthetic hand with
  webcam-like noise (drift, tap, double tap, drag, hand loss, flicks and the
  false-flick cases, the on/off toggle and what it blocks, momentum, filter and
  curve properties).

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
