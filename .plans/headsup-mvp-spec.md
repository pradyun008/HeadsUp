# HeadsUp MVP spec (two-day build)

Date: 2026-11-11. Source of truth for behaviour is `CLAUDE.md`; this file records the
decisions from the interview and where the MVP narrows or differs from it.

## Goal

In two days: live frames from Ray-Ban Meta Gen 3 glasses → on-device detection → tracking →
collision-course risk → spoken cue in the glasses ("bike, left"), with a debug screen that
shows why. The wristband is **not** part of this MVP.

**Must-have if time runs out:** glasses demo end to end (frames → boxes → risk → speech).
**May slip:** recording, settings polish, video-file harness, phone haptics.

## Decisions

| Topic | Decision |
|---|---|
| Test targets | Real iPhone + real Gen 3 glasses. Mac/Simulator for building and unit tests. |
| Glasses integration | DAT via SPM, written against current docs, with MockDeviceKit so it runs without glasses. Still build step 1. |
| DAT reference | Reuse the working pattern from `~/Desktop/meta_chess/ios/MetaChess` (DAT 1.0.1, Developer Mode, `Wearables.configure()`, `handleUrl`, `MWDAT` Info.plist dict, external-accessory protocol `com.meta.ar.wearable`). Read-only; verify against current docs, docs win. |
| Meta registration | Developer Mode (no app ID / client token), as in the chess app. Confirm in step 1 that Developer Mode is still on in Meta AI. |
| Identity | Bundle ID `com.romanstash.headsup`, URL scheme `headsup://`, team `V9ZA4NRGGY`, free Apple ID (7-day builds, minimal entitlements). |
| Project generation | XcodeGen (`project.yml`), approved as a build-time tool. `.xcodeproj` is generated. |
| YOLO model | Claude exports `yolo11n` to Core ML with NMS in a Python venv outside the app (`yolo export model=yolo11n.pt format=coreml nms=True`). Python 3.14 may be too new for coremltools; use an older Python if needed. Model goes in `HeadsUp/Resources/`. |
| Test footage | Built-in **scripted scenario source** that feeds synthetic detections (bypasses YOLO) for "walks past" and "walks toward". Real clips through `VideoFileFrameSource` later. |
| Band | **Simulated only.** No Core Bluetooth in this MVP. Keep the `BandOutput` heartbeat logic (200 ms, wrist swap) behind a transport protocol with a simulated transport that drives the on-screen bars, so unit test 8 still passes and BLE drops in later. |
| Alert delivery | Speech in the glasses + on-screen level bars. No stereo ticks. `PhoneHapticOutput` is low priority and may slip. |
| Audio clash | Duck other audio during a cue, then restore. |
| Status speech | Speak critical states only: watching started, stream lost/paused (disconnected, hinges closed, thermal, battery), watching resumed. Hazard cues always pre-empt status speech. Wording reports state only; never "safe" or "clear". |
| Background | Foreground only. Idle timer disabled while watching. No background modes beyond what DAT needs. |
| Head-motion gate | Vision translational image registration on every source. Glasses IMU (`MWDATMotion`) is a follow-up. |
| Alert decay | Normal hysteresis: lost track coasts ~1 s, then levels step down by the 5-frame rule. |
| Crossing scan | Out of this MVP. |

## Differences from CLAUDE.md (deliberate, agreed)

1. Step 7 (BandOutput over BLE) is replaced by a simulated band transport. UUID constants file still exists with the `// TODO: match the band firmware` marker.
2. Step 9 (crossing scan) is not built.
3. A scripted scenario `FrameSource`/detection source is added for repeatable demos without footage.
4. Status speech for stream state is added (not in CLAUDE.md).
5. XcodeGen is used to generate the project.

## Build order for the two days

1. XcodeGen project, DAT package, Info.plist per chess pattern + current docs; `GlassesFrameSource` (low res, 15 fps) with state/error messages and mock device; live frames + fps on screen. User checklist for Meta AI Developer Mode / registration.
2. `PhoneCameraFrameSource`; scripted scenario source. (`VideoFileFrameSource` + Record after the core works.)
3. Export model; `Detector` (drop-if-busy, class filter, normalized x in −1…+1); boxes on debug screen.
4. IoU tracker with 1 s coasting and ring buffers; IDs on screen.
5. `RiskEstimator` + unit tests 1–7 with synthetic tracks.
6. `AlertPolicy` (3-up / 5-down hysteresis, per-side max), `SpeechOutput` (Bluetooth route, ducking, one utterance max, 4 s per-track repeat guard), status speech.
7. Simulated band: heartbeat + wrist swap + unit test 8; on-screen bars.
8. Latency measurement (frame timestamp → simulated band write, detection time), debug screen polish, settings screen.
9. If time: video-file source, recording, video harness log, phone haptics.

Each step ends with: build, run tests, commit, 2–3 line summary.

## Open items / risks

- Meta setup state is unconfirmed ("I think Developer Mode is on"). First device run verifies it.
- A second DAT app in Developer Mode alongside the chess app is assumed to work; unverified.
- Free signing: 7-day expiry; re-install before the demo.
- Speech through glasses speakers while DAT camera streaming is active is unverified; test early in step 6.
- Simulator Core ML speed is not representative; latency numbers only count on the iPhone.
- Hard rules from CLAUDE.md stand: no instructions or safety verdicts, no cloud in the hazard loop, camera-relative left/right stated in code and UI.
