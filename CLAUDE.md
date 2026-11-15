# HeadsUp — iOS app (software only)

Instructions for Claude Code. Read this whole file before writing any code.

## Background

HeadsUp is a wearable for blind and low-vision pedestrians, built for HackPrinceton (Fall 2026). A person wears Meta Ray-Ban glasses (Gen 3) and a small wristband with two vibration motors, one per side. The glasses camera streams video to an iPhone app. The app spots people, bikes, scooters and cars, works out which ones are on a **collision course** with the wearer, and warns about those. It does this by buzzing the side of the band that matches the danger and speaking a short cue ("bike, left") through the glasses' speakers.

What makes it different from smart canes and other blind-assist tools: those alert on **proximity**, and in a city everything is close, so users get buzzed constantly and switch them off. HeadsUp uses the old sailor's rule: **constant bearing and decreasing range means collision.** Someone walking past is ignored. Someone heading straight at you triggers a warning. The demo is exactly that: one person walks past and nothing happens, another walks straight at the wearer and the band buzzes.

HeadsUp works **alongside** the white cane, never instead of it. The cane handles the ground and static obstacles. HeadsUp handles moving things.

Hackathon rule: work may begin Nov 11, 2026, locally. Keep everything in a local git repo and commit often with clear messages.

## Hard rules for this project

1. **Never tell the user what to do or that something is safe.** No "safe to cross", "go", "move right" or "you're clear". Output only reports what was seen: "bike, left", "car ahead". A left buzz means "hazard on your left", not "move right". One exception, for navigation only: route cues such as "turn left" are wayfinding, and are allowed. They still never say anything is safe, and a crosswalk is mentioned only as something an aerial photo showed ("at a marked crosswalk"), never as "no crosswalk".
2. **No cloud in the hazard loop.** Detection, tracking, risk and output all run on-device. A network round trip is too slow for something coming at you.
3. **Don't guess Meta SDK APIs.** The Meta Wearables Device Access Toolkit (DAT) is new and changes often. Before writing glasses code, read the official iOS integration docs (wearables.developer.meta.com/docs/build-integration-ios) and Meta's CameraAccess sample app, and copy their patterns. If something in this file conflicts with the current docs, the docs win. Tell me about the conflict.
4. **Left/right is camera-relative.** The camera follows the head, not the body. Say so in code comments and UI text.
5. **Out of scope, do not build:** indoor navigation, emergency/caregiver calling, fall or crash detection, a conversational assistant, any "safe to cross" verdict.
6. Ask before adding any third-party dependency beyond the Meta DAT package and a YOLO Core ML model. Already approved for the laptop server only (`server/`): fastapi, uvicorn, httpx.
7. **Navigation never touches the hazard loop.** The band stays hazard-only. Hazard speech always goes before navigation speech. Network use is allowed for navigation (Apple Maps, the route-intel server) and still forbidden in the hazard loop.
8. **CoStar organizer rule:** no floor plans, Matterport model IDs or property-identifiable geometry in the repo or README. Keys and the model ID live in the git-ignored `server/.env`.

## Navigation (added Nov 14)

Voice-only walking directions sit beside the hazard loop: the wearer presses the HeadsUp button, says a destination, and hears turn-by-turn cues in feet. The design is in `.plans/headsup-navigate-spec.md`; how it fits with the "Is it moving?" hazard logic is in `.plans/navigate-on-main-spec.md`; team decisions are in `.plans/decision-log.md`. Code is in `HeadsUp/Nav/`, the laptop server in `server/`.

`xcodegen` is not installed on Roman's Mac. After adding Swift files, run `python3 tools/sync_xcodeproj.py` to add them to the Xcode project, and keep `project.yml` in step by hand.

## Platform

- iOS 17+, Swift, SwiftUI, Xcode. iPhone only.
- Meta Wearables DAT for iOS via Swift Package Manager.
- Vision + Core ML for detection, Core Bluetooth for the band, AVFoundation for speech and the phone-camera fallback, Core Haptics for the phone-vibration fallback.

## Architecture

Build everything behind small protocols so each piece can be swapped and tested alone. The pipeline is:

```
FrameSource → Detector → Tracker → RiskEstimator → AlertPolicy → Outputs (band, speech, phone haptics) + Debug UI
```

### 1. FrameSource (protocol)

Emits `(CGImage or CVPixelBuffer, timestamp)` frames.

- `GlassesFrameSource`: Meta DAT camera stream. Per Meta's docs, valid frame rates are 2, 7, 15, 24 and 30 fps, and resolutions are low 360×640, medium 504×896 and high 720×1280. The stream rides Bluetooth Classic, and Meta says lower settings often give *better* image quality because of less compression. Start at **low resolution, 15 fps**. Handle stream states and errors (permission denied, device not connected, hinges closed, thermal, battery low) with clear on-screen messages. Use DAT's mock device support if it exists in the current SDK, so the app can be developed without glasses.
- `PhoneCameraFrameSource`: the iPhone's rear camera via AVCaptureSession, same output format. This is the fallback if the glasses stream doesn't work, and it's useful for desk testing.
- `VideoFileFrameSource`: plays a recorded .mov at its native frame rate. Used for repeatable testing and as a demo backup.
- Add a **Record** button in debug mode that saves the incoming frames from any source to a .mov in the app's Documents folder, so real glasses footage can be replayed later.

### 2. Detector

- YOLO nano model (YOLO11n or YOLOv8n) converted to Core ML with NMS included (`yolo export model=yolo11n.pt format=coreml nms=True`). Load it with `VNCoreMLModel` and run `VNCoreMLRequest`. If the model file isn't in the project yet, stop and tell me the exact export command and where to put the file.
- Keep only these COCO classes: person, bicycle, motorcycle, car, bus, truck. Note: COCO has no "scooter" class, and scooter riders usually show up as person. That's fine.
- Confidence threshold ~0.4, configurable.
- Output boxes in **normalized coordinates**: x from −1 (left edge) to +1 (right edge), with 0 at the frame center.
- Run detection off the main thread. If a frame is still processing when the next one arrives, drop the new one. Never queue frames.

### 3. Tracker

- Simple IoU-based tracker (a ByteTrack-lite is fine): assign stable IDs, match by IoU plus class, and keep a track alive for ~1 s without detections (coasting on its last velocity) so a brief occlusion or head turn doesn't reset it.
- Each track stores a ring buffer of the last ~1 s of observations: timestamp, left edge, right edge, center x, box height, box area.

### 4. RiskEstimator (the core; get this right)

For each track with at least ~0.4 s of history:

**Looming / time-to-contact.** Let `s = sqrt(box area)`. Fit a least-squares line to `ln(s)` vs time over the window. The slope `k` is the expansion rate. If `k <= 0`, the object isn't approaching: no risk. Otherwise `tau = 1 / k` seconds (time-to-contact estimate). This needs no depth sensor.

**Collision course (center drift).** Fit a line to the box's left edge and right edge over the window, to get edge velocities `vL` and `vR`. Predict the edges at contact: `L* = L + vL·tau`, `R* = R + vR·tau`. The object is **on course** if the predicted interval `[L*, R*]` overlaps the wearer's corridor `[−c, +c]` (start with `c = 0.15`, configurable). If the box grows but slides out of the corridor, it's **passing**, so stay quiet.

**Head-motion gate.** When the wearer turns their head, everything in the frame shifts sideways, and that would fake or hide drift. Estimate the global frame shift between consecutive frames with `VNTranslationalImageRegistrationRequest` (or the DAT motion/IMU data if the current SDK exposes it; check the docs). Subtract the global shift from every track's edge positions before fitting. If the shift rate is above a threshold (configurable, start around 0.5 normalized units per second), mark the frame **unstable**: keep tracking, but hold the current risk levels instead of updating them.

**Risk level** (only for on-course tracks; all thresholds configurable):

| tau | Level |
|---|---|
| > 4 s | 0 none |
| 2.5–4 s | 1 low |
| 1.5–2.5 s | 2 high |
| < 1.5 s | 3 urgent |

**Side** (camera-relative), from the predicted center at contact: left of −0.15 → LEFT, right of +0.15 → RIGHT, otherwise AHEAD.

Known limitations (document them, don't try to solve them):
- Walking toward any stationary object in the kept classes, such as a standing person or a parked car directly in the path, is a real relative approach and **will** trigger. That's expected. Parked cars *beside* the path should not trigger, because they slide toward the frame edge as the wearer passes, so the center-drift check marks them as passing. The class filter removes poles and walls, which are the cane's job.
- The prototype assumes the wearer is facing roughly the way they're walking. The camera's center is the head's direction, not the travel path.
- The head-motion step is an approximation, not true compensation. One global image shift can't fully account for rotation plus objects at different depths. Its real job is to **pause judgment** during fast head turns. Never claim tracking stays reliable through them.

### 5. AlertPolicy

- Smooth: a level must hold for 3 consecutive frames to go up and 5 frames to go down (hysteresis), so jitter doesn't make the band flicker.
- Combine all tracks into one output: `leftLevel` and `rightLevel` (0–3). LEFT drives left, RIGHT drives right, AHEAD drives both. Take the max per side.
- Speech: when a track first reaches level ≥ 2, say `"<class>, <side>"` (for example "bike, left", "car, ahead"). Say "bike" for bicycle/motorcycle and "car" for car/bus/truck. Don't repeat the same track within 4 s. Never queue more than one utterance; newer and higher-risk cues replace older ones.

### 6. Outputs (protocol)

- `BandOutput` (Core Bluetooth): scan for a peripheral named **"HapticBand"**, connect, and write 2 bytes `[leftLevel, rightLevel]` (each 0–3) with write-without-response **every 200 ms**, even when nothing changed. The band firmware turns motors off if it hears nothing for 600 ms, so the heartbeat matters. Put the service and characteristic UUIDs in one constants file marked `// TODO: match the band firmware`; my teammate's firmware defines them. Auto-reconnect if the connection drops, and show connection state in the UI.
- `PhoneHapticOutput`: Core Haptics fallback. With one motor, encode side as a pattern: one pulse = left, two = right, a long buzz = ahead, with pulse rate rising with level.
- `SpeechOutput`: `AVSpeechSynthesizer`. Configure the audio session so speech plays through the connected Bluetooth audio device (the glasses' speakers).
- A **"which wrist"** setting that swaps the left and right channels sent to the band. Treat the two motors as two learned cues ("left cue", "right cue"), not as intuitively spatial directions, since outer and inner wrist don't stay left and right as the arm rotates. Use that wording in UI text.

### 7. Screens

- **Main screen:** big status ("Watching" / "Glasses disconnected" / ...), source picker (Glasses, Phone camera, Video file), band connection state, and start/stop. Large text and full VoiceOver labels, since the wearer may be blind.
- **Debug screen** (this is for judges, so make it clear and readable): live frame with boxes, each labeled with class, track ID, tau and risk level. Boxes are colored by state: grey = not approaching, blue = passing, orange/red = on course by level. Draw the corridor lines at ±c. Add a head-motion "unstable" indicator, current left/right levels as two bars, fps, and **end-to-end latency** (frame timestamp → band write, plus detection time per frame) as a rolling average. Show tau labeled "est." because it's an estimate.
- **Settings:** all thresholds above, which wrist, voice on/off, and haptics output (band, phone, both).

## Testing

Write unit tests for the risk math with **synthetic tracks** (no camera needed). These must pass:

1. Object straight ahead, growing steadily → on course, level rises as tau drops, side AHEAD.
2. Object starting slightly left, growing, edges staying around the corridor → on course, side LEFT.
3. Object growing but sliding toward the edge (passing at about 1 m) → passing, level 0.
4. Object not growing (someone walking across far away) → level 0.
5. Object shrinking (moving away) → level 0.
6. A sudden global shift of every box (head turn) → frame marked unstable, levels held and not raised.
7. Hysteresis: a one-frame spike to level 3 does not change the output.
8. Band heartbeat sends every 200 ms, and the wrist swap flips the channels.

Then build a test harness that runs `VideoFileFrameSource` clips through the full pipeline and prints a per-frame log (track, tau, course, level). I'll record real clips of someone walking past and someone walking toward the camera.

## Build order (each step must work before the next)

1. **Glasses stream.** Xcode project, DAT installed, app registered as Meta's docs require, live frames from the glasses on screen with fps shown. This is the riskiest step, so do it first. If it's blocked, tell me exactly what's failing and switch to `PhoneCameraFrameSource` so everything else can continue.
2. `PhoneCameraFrameSource`, `VideoFileFrameSource` and recording.
3. Detector, with boxes drawn on the debug screen.
4. Tracker, with stable IDs on screen.
5. RiskEstimator plus all unit tests passing.
6. AlertPolicy plus SpeechOutput plus PhoneHapticOutput (fully testable without the band).
7. BandOutput over BLE.
8. Latency measurement and debug screen polish.
9. Stretch, only if 1–8 are solid: a **crossing scan**. Triggers, in order of priority: (a) the voice phrase "HeadsUp, crossing" via the glasses' mic (on-device speech recognition with `SFSpeechRecognizer`, `requiresOnDeviceRecognition = true`), (b) an on-screen button and an App Intent so the iPhone's Back Tap or Action button can launch it, (c) if time allows, an auto-trigger when the phone's motion data shows the user has stopped walking for ~3 s. When triggered, speak "Look left," wait ~2 s, say "Look right," then report only what was seen ("car, left" or "nothing seen"). Never a verdict about crossing, never read or announce walk signals, and no map/GPS crosswalk detection.

At the end of each step: build, run the tests, commit, and give me a 2–3 line summary of what works and what doesn't.
