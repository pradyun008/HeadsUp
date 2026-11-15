# HeadsUp

A wearable for blind and low-vision pedestrians that warns only about things on a **collision course**. Built at HackPrinceton, Fall 2026.

The wearer has Meta Ray-Ban glasses and a wristband with two vibration motors. The glasses camera streams video to an iPhone. The phone finds people, bikes and cars, works out which ones are heading at the wearer, and buzzes the matching side of the band. It also speaks a short cue such as "person, left" through the glasses.

## Why

Most assistive tools alert on **proximity**. In a city everything is close, so they buzz all the time and people switch them off.

HeadsUp uses the sailor's rule: **constant bearing and decreasing range means collision.** Someone walking past is ignored. Someone heading straight at you triggers a warning.

HeadsUp works alongside the white cane, never instead of it. The cane handles the ground and fixed obstacles. HeadsUp handles moving things. It only reports what it saw. It never says that something is safe.

## How it works

```
Glasses camera → iPhone: detect → track → judge risk → decide alerts → band, speech, phone vibration
```

Everything in this loop runs on the phone. No network is used, because a round trip is too slow for something coming at you.

1. **Detect.** A YOLO11n vision model (Core ML) finds people, bicycles, motorcycles, cars, buses and trucks in each frame.
2. **Track.** Each object keeps one ID across frames, and survives about a second of being hidden.
3. **Judge risk.** Four checks, in order:
   - **Getting closer?** The object's box grows as it nears. The growth rate gives the time to contact ("tau") with no depth sensor.
   - **Heading at me?** The box is predicted forward to the moment of contact. If it ends up in the strip the wearer is walking into, it is on course. If it slides out, it is passing, and the app stays quiet.
   - **Is it moving?** If the wearer is walking, their own speed is subtracted. A standing person the wearer walks toward is not a moving hazard, so it is not announced.
   - **Soon enough?** The time to contact sets a level from 0 to 3.
4. **Decide alerts.** Levels are smoothed so the band does not flicker. With several objects, the one with the least time to contact comes first.
5. **Output.** Each side of the band buzzes at a strength that rises with the level. Speech starts at level 2.

| Time to contact | Level | Band |
|---|---|---|
| more than 5 s | 0 | off |
| 3.5–5 s | 1 | gentle |
| 2–3.5 s | 2 | medium, and a spoken cue |
| under 2 s | 3 | strong |

Left and right are relative to the camera, which turns with the head.

## What is AI and what is not

- **AI:** the YOLO vision model that finds objects, Apple's on-device speech recognition for the voice command, and the aerial-image crosswalk detection used by navigation.
- **Not AI:** tracking, time to contact, the collision-course check and the alert logic. This is geometry and physics written by hand, covered by unit tests.

## Other features

- **Head-turn handling.** A fast head turn shifts the whole image. The app notices and holds its judgments until the view settles.
- **Walking detection.** The phone's motion sensor tells walking from standing within about 1.5 seconds.
- **Suspicious jumps.** When two people's boxes merge, or someone steps in front, the sudden size jump is kept out of the time-to-contact estimate.
- **Voice navigation.** Press the HeadsUp button, say a destination, and hear turn-by-turn walking directions. Hazard warnings always go first. Navigation uses Apple Maps and a small laptop server (`server/`) that checks aerial imagery for marked crosswalks at turns.
- **Debug screen.** Shows the live frame with boxes, time to contact, levels, latency and the band's connection state.
- **Scripted scenes.** Built-in fake scenes drive the whole pipeline and the band with no camera, for testing and as a demo backup.

## Hardware

| Part | Role |
|---|---|
| Meta Ray-Ban glasses | Camera and speakers, through Meta's Wearables Device Access Toolkit |
| iPhone | All processing |
| Wristband | ESP32 with two vibration motors, over Bluetooth Low Energy |

The band firmware is `arduino_backend/esp_bluetooth.ino` on the `Vincent` branch. Every 200 ms the app sends each motor a strength and a short run time. If the app goes quiet, the motors stop by themselves within 400 ms.

## Measured on our devices

- Detection takes about 12 ms a frame, and frame-to-band about 17–19 ms, on the phone at 15 frames a second. The glasses' own Bluetooth delay is not included.
- Distance from box height was within about 7–12% of a tape measure from 3 to 8 m.
- A person running at the wearer was flagged from about 7 m.

## Known limits

- **Crowds.** Overlapping people cause ID swaps and merged boxes, which can give a false warning or a missed one.
- **Low light and distance.** Detection is poor in the dark and beyond about 8 m.
- **Head direction.** The camera follows the head. The app assumes the wearer faces roughly where they walk.
- **Standing people.** A standing person the wearer walks toward is sometimes labelled as passing.
- **Estimates.** Time to contact, distance and walking speed are all estimates, and their errors add up. The design leans toward warning.
- **Band.** If the band disconnects, the app does not yet announce it or switch to phone vibration by itself.

## Run it

Requirements: a Mac with Xcode, an iPhone on iOS 17.2 or later, and for the full setup the glasses and the band.

1. Open `HeadsUp.xcodeproj` in Xcode and run the `HeadsUp` scheme on an iPhone.
2. On the Main tab, pick a source: **Glasses**, **Phone** (rear camera), **Video** (a recorded clip) or **Scripted** (no camera needed).
3. Press **Start**. The Debug tab shows what the app sees.
4. Power the band. The Debug tab shows "Band: connected" within a few seconds.

To try it with no hardware at all, pick **Scripted** and the scene "Past, then toward".

Tests:

```
xcodebuild test -scheme HeadsUp -destination 'platform=iOS Simulator,name=<an installed iPhone simulator>'
```

There are 139 unit tests, built on synthetic scenes with no camera. One test that records a short clip is known to fail now and then on the simulator.

Navigation server (optional), on a laptop the phone can reach:

```
cd server && pip install -r requirements.txt && uvicorn main:app --host 0.0.0.0 --port 8000
```

Its keys go in `server/.env`, which is not in the repository.

## Repository

| Path | Contents |
|---|---|
| `HeadsUp/Sources` | Frame sources: glasses, phone camera, video file, scripted scenes |
| `HeadsUp/Core` | Detector, tracker, risk estimator, alert policy, walking detection |
| `HeadsUp/Outputs` | Band over Bluetooth, speech, phone vibration |
| `HeadsUp/Nav` | Voice navigation |
| `HeadsUp/UI` | Main, Debug, Route, Settings and onboarding screens |
| `HeadsUpTests` | Unit tests |
| `server` | Route-intel server for navigation |
| `.plans` | Specs and the team's decision log |

## Team

Pradyun, Roman, Eric and Vincent.
