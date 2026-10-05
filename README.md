# Scrollpage

Your hand is the trackpad. Scrollpage is a macOS menu bar app that watches your
right hand through the webcam (Apple Vision hand pose) and moves the pointer,
clicks and scrolls system-wide, with the motion model of an Apple trackpad:
relative pointer motion with acceleration, tap-to-click, two-finger scrolling
and momentum.

No keyboard is involved at all: no hotkeys, no modifier combos, no synthesized
key presses.

## Gestures

All gestures are made with the **right hand**; the left hand is ignored, even
alone in the frame.

| Do this | Get this |
| --- | --- |
| Make an **OK sign** (thumb and index tips touching, middle, ring and little fingers extended) and move | Move the pointer (one finger on the pad). Slow is precise, fast crosses the screen. |
| Hold the OK sign and turn your hand at the wrist | Move the pointer too: turn right/left goes right/left, tipping the knuckles up/down goes up/down. |
| Quick OK-sign touch without moving | Click. Two quick touches double-click, three triple-click. |
| Touch, hold still ~0.6 s, then move | Drag (mouse button held until you let go). |
| Touch thumb, index **and middle** tips together (ring and little extended) and move | Scroll (two fingers on the pad): the page follows your hand, any direction. Let go while moving and it glides. |
| Flick an open hand up/down/left/right | Momentum scroll, like a two-finger fling. |
| Touch while the page glides | Catch the glide (stops it at once). |
| Fingers apart, open hand, fist, half-closed hand, or hand out of view | Fingers lifted: nothing moves. |
| Raise a palm, all five fingers spread, hold still ~1 s | Turn gestures off, or back on. |

The pointer is relative, like a trackpad: parting the fingers is lifting your
finger, so you can "clutch" (let go, move the hand back, touch again) to keep
going in one direction.

### Touch means touch

Only fingertips that actually touch count. Fingertips held just apart, however
close, never move the pointer: a hand that is almost pinching is a finger
hovering over the pad. Distances are measured between fingertips in hand sizes
(wrist to middle knuckle). The thresholds come from two guided calibration runs
(`--calibrate-pinch`, frames after each step's first 1.5 s) and four earlier
recordings, on a 1080p USB webcam at 30 fps:

| Thumb tip to index tip | Hand sizes |
| --- | --- |
| Touching, calibration run 1: median / p90 / p95 | 0.045 / 0.059 / 0.067 |
| Touching, calibration run 2: median / p90 / p95 | 0.081 / 0.107 / 0.112 |
| Touching, earlier recordings: median / p95 | 0.026 / 0.039 |
| Hovering a hair apart, run 2 (the tightest): p5 / median / p95 | 0.079 / 0.099 / 0.120 |
| Hovering just apart, earlier recordings: p10 / median | 0.129 / 0.189 |
| Open hand | 0.3 and up |

- **Enter at 0.08, leave at 0.12.** Run 2's touch and hover overlap (touching
  reads up to 0.11, hovering down to 0.08), so no single line splits every
  frame: entering below nearly all hovering frames and leaving above nearly all
  touching ones keeps a hover from ever starting a touch and a held touch from
  flickering off. Starting at 0.09 already caught run 2's hover. Above 0.10 the
  fingers are parting, so the pointer stops: letting go doesn't drag it.
- **Three frames to confirm** (0.1 s at 30 fps). Up to two frames that wobble
  out to between 0.08 and 0.12 don't count, but don't start the count over
  either; a third does. Forgiving any number let run 2's hover, which brushes
  0.08 every second or so, add up to a touch. A touch also needs the fingers to
  have been seen apart (above 0.12) first, so a hand that arrives already
  pinched doesn't grab; letting go counts, so a near touch that let go doesn't
  swallow the real touch right after it.
- **Confident fingertips only.** Thumb and index tips Vision reports with
  confidence under 0.4, and middle tips under 0.3 (half hidden behind the
  thumb in the three-finger pose, they read 0.37 median), can't start a touch.
  During a touch, unreadable frames hold it for 0.2 s; after that it ends
  without a click.
- **No flick while reaching.** A fast move with the thumb within 0.25 of the
  index is someone reaching for a pinch, so it doesn't fling.

Replaying the two calibration runs through the engine (`--diagnose --replay`,
the same 1.5 s left out of each step), with the earlier thresholds (0.06 /
0.10, all three tips within 0.12) and now:

| Pose | Want | Run 1 earlier → now | Run 2 earlier → now |
| --- | --- | --- | --- |
| Touching | pinch held | 95 % → 99 % | 0 % → 50 % |
| Hovering a hair apart | nothing | 0 % → 9 % (see below) | 0 % → 0 % |
| Three fingertips together | scroll held | 0 % → 100 % | 0 % → 56 % |
| Touching, other fingers curled | nothing | fingers weren't curled | 0 % → 0 % |

Run 1's hover has one 0.4 s touch 2.5 s in, while the hand was still arriving
(the tips swung in to 0.058, a real brush); from 3 s on it's 0 %. Run 2's
three-finger step ends with an OK sign for its last second, which the pinch
correctly picks up. In run 1's curled step the other fingers stayed straight
(tip-to-wrist ratio 1.1, angle 160°), so it is an OK sign and pinches.

Your hand and camera may differ. `Scrollpage --calibrate-pinch` walks you
through open, touching, hovering, three-finger and curled poses and prints
your percentiles next to the thresholds (see [Diagnostics](#diagnostics)).

### The OK sign

The pointer pinch is an OK sign: besides the thumb and index tips touching,
the middle, ring and little fingers must be extended. A fist or a half-closed
hand with the thumb on the index never moves the pointer. Each finger is judged
by how much farther its tip is from the wrist than its middle joint (PIP), a
ratio that doesn't change as the hand rotates and needs no hand size. Measured
on the same webcam (five sessions, about 850 frames per finger), it splits
cleanly:

| Tip-to-wrist over PIP-to-wrist | Middle | Ring | Little |
| --- | --- | --- | --- |
| Curled (most frames) | 0.60 – 0.80 | 0.60 – 0.80 | 0.60 – 0.80 |
| In between (rare) | 30 frames | 20 frames | 29 frames |
| Extended (most frames) | 0.95 – 1.40 | 0.95 – 1.40 | 0.95 – 1.40 |
| While thumb and index touch: p5 / median | 1.14 / 1.22 | 1.09 / 1.18 | 1.06 / 1.13 |
| PIP angle, curled p90 / extended p10 | 110° / 128° | 105° / 124° | 108° / 127° |

- **Extended at 0.92, curled below 0.85.** A relaxed but extended hand (the
  little finger's 5th percentile while touching is 1.06) clears 0.92 easily,
  and a finger has to curl well past the gap to count as curled. Between the
  two the finger keeps its state, so a finger wobbling at either edge never
  flickers. Frame-to-frame noise of the ratio is about 0.01; the gap is 0.07.
- **The joint angle decides when the ratio can't.** When the ratio is between
  0.80 and 0.92, or the wrist or tip can't be seen (a foreshortened or cropped
  hand), the angle at the middle joint decides: 120° or straighter is extended,
  under 112° curled.
- **Two frames to change state**, and the touch itself still needs its three
  confirming frames. Every real pinch frame in the recordings has all three
  fingers extended, so replays touch exactly as before.
- **A twitch doesn't drop a drag.** If one of the three fingers curls during a
  touch, the pointer pauses but the touch (and the mouse button, when dragging)
  holds for 0.3 s. Extend it again and carry on; keep it curled and the touch
  ends without a click.
- **Three-finger scroll** needs the ring and little fingers extended, by the
  same rule: the fingers off the pad are up, so a fist with three tips together
  doesn't scroll either. The middle finger is the one curling to the thumb
  there, so it isn't checked.

### Turning the hand

While the OK sign is held, turning the hand at the wrist moves the pointer as
well as moving the hand does. The angle comes from the vector from the wrist
to the index and middle knuckles: its angle in the image (yaw) and its length
against a slow 1.5 s reference (pitch: it shortens as the hand tips toward or
away from the camera). Both become pointer motion at **2 hand units per
radian**, in screen axes: turning the fingers to the right goes right (the
frame is mirrored like the preview), the knuckles rising from the wrist go up,
whichever way the hand leans.

- **Counted once.** Turning at the wrist also moves the knuckles, by 1 hand
  unit per radian. That part of the palm's motion is taken back out, so a turn
  at the wrist moves the pointer as far as sliding the hand 2 hand units per
  radian would, not 3, and sliding the hand without turning it moves exactly as
  before. At lever 1 the replays reproduce the old pointer travel within 2 %.
- **Same pipeline.** Translation plus turn goes through the same One Euro
  filter and velocity-based acceleration, so a 10° turn is about 60 pt slowly
  and up to about 600 pt quickly (6 to 60 pt per degree at the default
  Tracking speed).
- **No drift.** The knuckle vector is One Euro filtered first (0.5 Hz at rest),
  and turns slower than the pointer's own rest speeds (0.06 rad/s, fading in
  fully by 0.2 rad/s, measured at the knuckles) add nothing. A still hand reads
  0.5° to 0.65° of frame-to-frame yaw noise. Still or slowly swaying (±3°)
  with webcam-like noise, and on the recorded still hand, the pointer drifts
  0.00 pt/s (the target is under 1).
- **Only while pointing.** Scrolling, flicks and the on/off toggle follow the
  hand's position only. Wrist and knuckles below 0.5 confidence switch the
  angle off and the pointer follows the palm alone.

### Three-finger scroll

Thumb, index and middle tips together are two fingers on the pad. Moving the
hand scrolls the content one to one, in any direction: at the default Scrolling
speed, a hand length (~10 cm) of motion scrolls 500 points, and the slider sets
250 to 1000. Events are pixel-precise continuous scroll events with the
trackpad's phases (began, changed, ended), eased across the 120 Hz driver
ticks, so the page moves smoothly between camera frames. The pointer doesn't
move while scrolling.

Let go while still moving and the content glides on. The release velocity is a
least-squares fit over the last 100 ms of contact, newer frames weighted up to
twice as much, so one jittery frame doesn't decide it; slower than 150 pt/s
doesn't glide. Any new touch stops the glide at once, like a finger landing on
the pad.

Three tips can't meet at one point, so each pair has its own limit, from the
calibration runs' three-finger step:

| Three fingertips together | Thumb–index | Thumb–middle | Index–middle | Thumb to the nearer |
| --- | --- | --- | --- | --- |
| Run 1: median / p90 | 0.108 / 0.168 | 0.106 / 0.131 | 0.202 / 0.219 | 0.090 / 0.109 |
| Run 2 (0.5 to 4.5 s, while held): median / p90 | 0.103 / 0.163 | 0.069 / 0.128 | 0.146 / 0.222 | 0.057 / 0.084 |
| Starts at or below | 0.18 | 0.18 | 0.26 | 0.12 |
| Lets go above | 0.22 | 0.22 | 0.32 | – |

Index and middle sit side by side on the thumb, a fingertip apart, so their
limit is wider; the old single limit of 0.12 for all three never started a
scroll in either run. The thumb must also touch one of them: a hand closing
between quick pinches brings index and middle together (0.09 apart) with the
thumb 0.14 from both, inside every pair limit, and would otherwise scroll.
While scrolling, the content follows only as long as the pairs stay within
0.20 / 0.29, so parting fingers don't jerk it.

The two touches can't be confused. A plain pinch needs the middle tip at least
0.18 from the thumb and index tips, which is where the three-finger
thumb–middle limit ends, so a frame is one or the other (exactly on the line,
three-finger). Real pinches clear it with room to spare (the middle tip 0.52
away at p5 in calibration; 0.18 to 0.22 in quick pinches on a small hand, which
the old 0.22 rejected), and across all recordings no three consecutive frames
of a pinch came inside the three-finger limits. The middle finger also isn't
extended in 94 % of three-finger frames, so the OK sign alone rules out a
pinch there. Once a touch begins its kind is locked until you let go: the middle
finger drifting in during a pinch doesn't turn it into a scroll, and the middle
finger leaving ends a scroll rather than turning it into a pinch. A scroll
given up because the middle tip couldn't be read resumes when it can be,
without the thumb and index having to part first.

### Right hand only

Vision labels each hand left or right (`VNHumanHandPoseObservation.chirality`).
Scrollpage's camera frames are not mirrored (it mirrors coordinates itself), so
the label is the physical hand; if the capture connection ever reports mirrored
frames, the label is flipped back. Checked live: the hand labelled right was on
the user's right side of the mirrored frame with its thumb toward the body, on
44 of 47 frames; the hand labelled left was on the user's left. The preview
tags every hand R or L so you can check yours.

Up to two hands are detected. A right-labelled hand must be seen on three
frames in a row before it drives anything, and is then followed by palm
position. Vision's label sometimes flickers: during a gesture, the followed hand
may read left for up to 0.4 s without interrupting it. A flip lasting longer
drops the hand, which ends the gesture without a click, as if the hand had left
the frame. A palm that jumps farther than a hand can move between frames (a
tracking glitch, or another detection) is treated as a new hand, so the jump
never moves the pointer or scrolls.

### Why a quick touch for click

Pinch-and-move is the pointing gesture, so click had to be something that never
fires by accident while pointing and never moves the pointer. A trackpad solves
the same problem with tap-to-click: a touch that lifts quickly without sliding
is a click, a touch that slides is pointing. Scrollpage does exactly that with
the pinch:

- A pinch that releases within 0.35 s and stays within a small slop (about a
  tenth of a hand length) is a click. Until the slop is exceeded the pointer
  doesn't move at all, so the click lands exactly where you aimed.
- The pointer also freezes as soon as the fingers start to part, which removes
  the jitter of letting go (the main reason webcam clicks miss).
- Anything longer or with movement is pointing, so pointing never clicks.

Other options were worse: dwell-to-click fires while you are reading; "pinch
harder" has no reliable signal from a 2D camera.

### Flick to scroll

Besides the three-finger scroll, a quick flick of the open hand is recognized
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
- **Hand angle.** Turning the hand at the wrist adds to the motion, at 2 hand
  units per radian (see [Turning the hand](#turning-the-hand)).
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
`Scrollpage-<sha>.zip` artifact (kept 14 days; `v*` tags also publish a GitHub
Release). CI signs with the same self-signed identity as local builds, imported
from the repository secrets `SCROLLPAGE_SIGNING_P12` and
`SCROLLPAGE_SIGNING_PASSWORD`, so a CI build keeps the approvals given to a
local one (without the secrets it signs ad hoc, with a warning). To install the
newest green build of the current branch (needs the GitHub CLI):

```bash
scripts/install-latest.sh                      # to ~/Applications, unquarantined, then opens it
scripts/install-latest.sh --reset-permissions  # also reset the Accessibility grant
```

See [docs/ci.md](docs/ci.md) for options, manual installs, releases, signing
and Gatekeeper notes.

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
`identifier "com.saxocellphone.scrollpage" and certificate leaf = H"8e58a9e4…"`,
which stays the same across rebuilds and matches CI builds, so the grant only
has to be given once. Other options:

```bash
make build SIGN_IDENTITY=-   # ad hoc (what CI falls back to without the secrets)
make build SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

Copies with different signatures (an ad hoc build, a clone without the shared
identity) each need their own grant. If Scrollpage shows "Allow Accessibility"
while System Settings shows it switched on, click Allow: Scrollpage removes its
stale entry (`tccutil reset Accessibility com.saxocellphone.scrollpage`) so the
system prompt can add the running copy, then switch it on. `make
check-permissions` prints what the running build's signature and trust are.

## Settings

The menu bar popover has an on/off switch and three settings, nothing else:

- **Tracking speed**: mostly changes how far fast movements go, like the macOS
  slider.
- **Scrolling speed**: scales the three-finger scroll (250 to 1000 points per
  hand length) and the fling velocity.
- **Natural scrolling**: on means hand up moves the content up, like a
  trackpad with natural scrolling, for both the three-finger scroll and flicks.
  Defaults to the system setting.

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
right-hand detection rate and the chirality labels seen, thumb–index distance
percentiles against the thresholds, palm jitter, how far a still hand would
drift the pointer if pinched, every pinch and scroll down and up, and which
gestures fired. `--record` saves every frame's hands with their chirality;
`--replay` runs the hand selector and the engine over a recording, which is the
way to tune thresholds against real hands. (When run from a terminal, macOS
asks for camera access on behalf of the terminal app.)

```bash
build/Scrollpage.app/Contents/MacOS/Scrollpage --calibrate-pinch [--record calibration.jsonl]
build/Scrollpage.app/Contents/MacOS/Scrollpage --calibrate-pinch --replay calibration.jsonl
```

`--calibrate-pinch` is a guided measurement, about a minute, with a countdown
before each step: right hand open; thumb and index touching; thumb and index
just apart, not touching; thumb, index and middle touching; touching with the
other fingers curled (which must not count); left hand only. Each step records
1.5 s longer than it measures: the report leaves out that first stretch while
the hand gets into the pose. It prints fingertip distance percentiles for each
step (each pair for three fingers), how the current thresholds classify each,
suggested thresholds, and whether Vision's left/right labels match the hand
you used. The frames are saved (to `/tmp` unless `--record` is given); with
`--replay` it reports on a saved run with the current thresholds, and
`--diagnose --replay` adds a table of what the engine did in each pose (pinch
or scroll held, begins, clicks, travel), with control switched back on at each
step since holding the open hand still toggles it off.

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

- `Sources/ScrollpageCore`: the pure, tested motion model: `HandSample` and
  `HandSelector` (right hand only), `TouchDetector` (pinch and three-finger
  touch), `FingerExtensionTracker` (the OK sign), `WristRotation` (hand
  angle), `OneEuroFilter2D`, `PointerAcceleration`, `FlickDetector`,
  `ToggleGestureDetector`, `MomentumScroller`, `FlingSequencer`, and
  `GestureEngine`, which turns hand samples into trackpad events.
- `Sources/Scrollpage`: the app: camera + Vision pipeline, CGEvent input
  driver, menu bar popover, status pill, touch ring, onboarding, diagnostics.
- `Tests/ScrollpageCoreTests`: XCTest suite driven by a synthetic hand with
  webcam-like noise (drift, tap, double tap, drag, hand loss, touch thresholds
  and a near-touch hand that never moves the pointer, the OK sign and curled
  fingers, wrist rotation and its drift, three-finger scroll and
  its glide, left/right hand selection, flicks and the false-flick cases, the
  on/off toggle and what it blocks, momentum, filter and curve properties).

## Re-testing after an update

1. `make build && make run` (or `scripts/install-latest.sh` for the CI build).
   Both are signed with the shared identity; if Scrollpage shows "Allow
   Accessibility", click it once.
2. Open the preview from the menu bar. Hold up both hands: the right one should
   be tagged **R** and drawn solid, the left **L** and faded.
3. With the right hand, bring thumb and index close without touching and move
   around: nothing moves. Make an OK sign (the tips turn green) and move: the
   pointer moves. A quick touch clicks; two double-click.
4. Keep the OK sign and turn the hand at the wrist without moving the arm:
   the pointer follows the turn. Rest the hand: the pointer stays put.
5. Touch thumb and index with the other fingers curled (a fist, or ring and
   little folded): the tips stay yellow and nothing moves. During a drag, twitch
   one finger closed and open again: the drag holds.
6. Touch thumb, index and middle (the tips turn cyan) and move up, down and
   sideways: the page follows. Let go while moving: it glides; touch again: it
   stops. The pointer stays put throughout.
7. Do the same with the left hand alone: nothing happens.
8. Optional: `build/Scrollpage.app/Contents/MacOS/Scrollpage --calibrate-pinch`
   and compare your percentiles with the thresholds above; then
   `--diagnose --replay` the saved file for what the engine did in each pose.

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
