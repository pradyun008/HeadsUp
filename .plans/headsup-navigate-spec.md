# HeadsUp Navigate — spec

Date: 2026-11-14. Branch base: `roman`. Source: "HeadsUp Navigate — Claude Code build plan" PDF, the CoStar reference bundle, and an interview with Roman.

## 1. What we are building

The wearer presses a button and says "I want to go to McDonald's". The app finds the nearest one by walking time, says which one it picked, and guides by voice: "In about 150 feet, turn left", "Turn left", "Walk straight for 400 feet". The existing hazard loop keeps running the whole time and always wins over navigation speech.

Time budget: **under 8 hours, one developer plus Claude Code.** Every phase must leave a demo that works. Phases 4 and 5 are cuttable.

## 2. Decisions from the interview

| Topic | Decision |
|---|---|
| Scope | Phases 0–4 and 6 of the PDF. **No** Matterport indoor routing (PDF phase 5). |
| Second CoStar layer | A Matterport **arrival blurb** only: one GraphQL call, spoken on arrival at Rabinowitz Hall. |
| API keys | In hand, never tested. Phase 0 tests them first. |
| Voice trigger | Button press, then the mic opens for about 6 s. No always-on listening. |
| The button | An App Intent bound to the iPhone **Action button** (Back Tap as the second choice). An on-screen button does the same thing. |
| Confirmation | Guidance auto-starts 3 s after the spoken confirmation. A button press in that window rejects it and reads the next result. |
| Mid-walk voice commands | Only **"stop" / "cancel"**. No repeat, no change-destination, no crossing scan by voice. |
| First cue | Clock direction from the compass ("Route starts at your 2 o'clock, on Nassau Street"). |
| Phone carry | In a pocket, screen on, app in the foreground. No background modes. |
| Server link | Phone fetches route intel **once before the walk** and caches it. No laptop calls while walking. |
| Server stack | `server/` in this repo. Python, FastAPI, uvicorn, httpx approved. Keys in a git-ignored `server/.env`. |
| Road crossings | Announce a crosswalk only at a turn, and only when Vexcel detected one. Nothing else about crossings. |
| Long straights | "Continue straight, 600 feet" about every 200 ft, lowest priority, skipped while any hazard is active. |
| Crossing scan (uncommitted) | Commit `CrossingScan.swift` and its tests as they are. Do not wire the voice phrase or the auto trigger. |
| Demo | Replay at the table (recorded GPS + recorded glasses video) with a live person walking at the wearer, plus a phone video of a real outdoor walk. |

## 3. Rules

These add to CLAUDE.md. Where they conflict, this section is the newer decision and CLAUDE.md must be edited to match (see 3.1).

1. **The hazard loop does not change.** No edits to detector, tracker, risk or alert timing. Navigation code never runs on the frame-processing queue.
2. **The band stays hazard-only.** A buzz always means a hazard. Navigation is voice only.
3. **Route cues are wayfinding, not safety advice.** "Turn left" is allowed. "Safe to cross", "go", "you're clear" and "no crosswalk" are never said. A crosswalk is mentioned only as something an aerial photo showed: "at a marked crosswalk".
4. **Hazard speech pre-empts navigation speech**, mid-sentence. The cut-off cue is spoken again afterwards with a freshly computed distance.
5. **All distances are in feet** in speech and UI. Round to 10 below 100 ft and to 50 above.
6. **Secrets** come from `server/.env` only. Never on the phone, never printed, never committed. Do not paste keys into chat.
7. **Organizer rule:** no floor plans, Matterport model IDs or property-identifiable geometry in the repo or README. The model ID lives in `server/.env` as `MATTERPORT_MODEL_ID`. Vexcel image tiles are cached outside git.
8. **Network is allowed for navigation** (MapKit search and routing, the one route-intel fetch). It is still forbidden in the hazard loop.
9. Handle empty, 403, 404, 429 and timeout responses explicitly. Every CoStar failure degrades to plain navigation without a spoken error.

### 3.1 CLAUDE.md edits

- Hard rule 1: add the wayfinding exception from rule 3 above.
- Hard rule 5: remove "point-A-to-B navigation" from the out-of-scope list. Add "indoor navigation" to it.
- Hard rule 6: list the approved server packages.
- Add a short "Navigate" section that points to this spec.

## 4. Architecture

```
Action button / on-screen button
        │
   VoiceCommand (mic ~6 s, on-device SFSpeechRecognizer)
        │  "take me to X" | "stop"
   DestinationSearch (MKLocalSearch → rank by MKDirections walking ETA)
        │  MKRoute
   RouteIntelClient ──(once, before the walk)──► laptop server ──► Vexcel, Matterport
        │  crosswalk flags per maneuver, arrival blurb
   NavigationEngine ◄── LocationProvider (CoreLocation | GPX replay)
        │  NavCue
   SpeechArbiter ◄── hazard SpeechCue from the existing AlertPolicy
        │
   SpeechOutput (existing)
```

New Swift files, all under `HeadsUp/Nav/`:

| File | Job |
|---|---|
| `LocationProvider.swift` | Protocol emitting `(coordinate, horizontalAccuracy, course, heading, timestamp)`. `CoreLocationProvider` (best-for-navigation accuracy) and `GPXReplayProvider`. |
| `VoiceCommand.swift` | Opens the mic, returns a transcript. Pure parser: `"take me to / I want to go to / navigate to X"` → `.destination(X)`; `"stop" / "cancel"` → `.stop`. |
| `DestinationSearch.swift` | `MKLocalSearch` near the current location, top 5 results, one `MKDirections(.walking)` request each, sorted by ETA. |
| `RouteGeometry.swift` | Pure maths: polyline snapping, distance along the route, bearing change at a maneuver, clock direction, feet rounding. |
| `NavigationEngine.swift` | State machine that turns positions into `NavCue`s. No MapKit types inside, so it is testable with plain coordinates. |
| `RouteIntelClient.swift` | One `POST /route-intel`, 8 s timeout, result cached to disk by route hash. |
| `SpeechArbiter.swift` | One ranked queue for all speech. Replaces direct calls to `speech.speak` in `AppModel`. |
| `NavIntent.swift` | App Intent "HeadsUp button" for the Action button and Back Tap. |
| `UI/NavPanelView.swift` | Navigation panel on the debug screen. |

Info.plist additions: `NSLocationWhenInUseUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`. No new background modes. Set `isIdleTimerDisabled = true` while watching or navigating.

## 5. Behaviour

### 5.1 The button

One button, meaning depends on state:

| State | A press does |
|---|---|
| Idle or navigating | Play a short start tone, open the mic for 6 s (stops early after 1.2 s of silence). |
| Confirming a destination (3 s window) | Reject it and read the next candidate. After the last one: "No more results." |

Navigation stops only by the voice command "stop" or "cancel", or the on-screen Stop button. A stray pocket press therefore cannot end a route.

### 5.2 Mic and audio

- While listening: `AVAudioSession` category `.playAndRecord`, mode `.measurement`, options `.allowBluetooth`, so the glasses mic is used when present. If no Bluetooth input is available, the phone mic is used.
- When listening ends, go back to the existing `.playback` / `.voicePrompt` setup so hazard cues return to good audio quality.
- `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`.
- A hazard cue of level ≥ 2 during listening ends the listening window at once and speaks. The request is lost; the wearer presses again.
- **Unverified risk:** opening the Bluetooth headset mic may disturb the DAT camera stream, which also uses Bluetooth Classic. Test in Phase 1. If the stream drops or stutters, use the phone mic always and record that here.

### 5.3 Search and confirmation

1. Transcript → destination text. Nothing usable: "Didn't catch that."
2. `MKLocalSearch` in a 3 km region around the wearer. No results: "No results for X."
3. Rank the top 5 by walking ETA. Speak: "McDonald's on Nassau Street, about 0.8 miles, 17 minutes. Starting." (Miles are used only in this sentence, for total trip length. Everything else is feet.)
4. Wait 3 s. A button press reads the next candidate. No press: fetch route intel (5.6), then start guidance. Guidance does not wait more than 8 s for intel.

### 5.4 Guidance cues

Position is snapped to the route once per second. Left or right comes from the bearing change at the maneuver, never from MapKit's instruction text. Bearing change under 30° is "continue", 30–150° is "turn left/right", over 150° is "turn around".

| Cue | When | Example |
|---|---|---|
| Start | Once, when guidance begins | "Route starts at your 2 o'clock, on Nassau Street." |
| Advance | ~150 ft before a maneuver | "In about 150 feet, turn left onto Witherspoon Street." With intel: "…turn left at a marked crosswalk." |
| Imminent | ~25 ft before | "Turn left." |
| After turn | Once the turn is complete | "Walk straight for 400 feet." |
| Reassurance | Every ~200 ft on a leg with no other cue due | "Continue straight, 600 feet." |
| Reroute | More than 25 m from the line for 10 s | "Rerouting." then a new route and a new Start cue |
| Arrival | Within 15 m of the destination | "You have arrived at McDonald's, on your right." Side is omitted if it can't be worked out. |

Each cue plays once per maneuver. If a leg is shorter than 150 ft, skip the Advance cue and go straight to Imminent.

**Start cue and the pocket.** The clock direction needs a compass heading, and a phone in a pocket often gives a bad one. Use the clock form only when `CLHeading.headingAccuracy` is 0–25°. Otherwise say "Head toward Nassau Street", and after 10 m of movement compare the GPS course with the route: more than 120° off → "Route is behind you." This fallback is my addition, not something Roman chose; it is needed because the two chosen answers (clock cue, phone in pocket) pull against each other.

**Direction of travel while walking** always comes from successive GPS points, not the compass.

### 5.5 Speech arbiter

Priorities, highest first:

| Rank | Kind |
|---|---|
| 5 | Urgent hazard (level 3) |
| 4 | High hazard (level 2) |
| 3 | Imminent turn, Arrival, Rerouting |
| 2 | Advance notice, Start, After-turn |
| 1 | Reassurance, search confirmation, status |

- A higher rank interrupts a lower one mid-sentence. Same rank waits.
- Navigation cues are stored as a **closure that builds the text**, not as a string. When a cue is replayed after a hazard, the distance is recomputed. If the maneuver has been passed by then, the cue is dropped.
- At most one navigation cue waits. A newer one replaces it.
- No new navigation cue starts while either side's hazard level is ≥ 2. Reassurance cues are skipped while any level is ≥ 1.
- The existing `SpeechQueue` rules for hazard cues (one pending, 4 s per-track repeat limit) stay as they are; the arbiter wraps them.

### 5.6 Route intel server (`server/`)

`POST /route-intel`

```json
{ "maneuvers": [{ "id": 0, "lat": 40.35, "lon": -74.65 }],
  "destination": { "name": "Rabinowitz Hall", "lat": 40.349, "lon": -74.655 } }
```

```json
{ "maneuvers": [{ "id": 0, "status": "ok", "crosswalk": true, "boxes": [[x, y, w, h]], "tile": "tiles/ab12.png" }],
  "arrival": { "blurb": "Rabinowitz Hall. Three floors, 32 rooms." } }
```

- For each maneuver inside the Princeton box (lon −74.694 to −74.598, lat 40.316 to 40.371): fetch a 60 m ortho square, then run `/elements/detect` with label `crosswalk`, threshold 0.5, buffer 0. Follow the request formats in `VEXCEL-AGENT-HANDOFF.md`; do not guess them.
- `status` is one of `ok`, `outside_box`, `forbidden`, `empty`, `rate_limited`, `timeout`, `error`. The phone treats everything except `ok` with `crosswalk: true` as "say nothing extra".
- Results are cached on disk per rounded coordinate, so a repeated route makes no Vexcel calls.
- **Arrival blurb:** if the destination is within 60 m of the model's `geolocation`, one Matterport GraphQL query (name, floors, rooms) builds the blurb. Any failure → `arrival: null`.
- The phone reaches the server at a base URL from Settings (laptop on the phone's hotspot). An empty URL means intel is off.
- The blurb is spoken after the Arrival cue, rank 1.

### 5.7 Debug navigation panel

Beside the hazard panel: a map with the route and the wearer's dot, the current step, distance to the next turn in feet, the last spoken cue, the arbiter's waiting cue, GPS accuracy, and intel status per maneuver. A second view shows the route over the cached Vexcel tiles with crosswalk boxes, for the judges.

### 5.8 Replay mode

`GPXReplayProvider` plus the existing `VideoFileFrameSource`, started together from one "Replay demo" control, with a pre-saved route so no network is needed. The whole demo must run with the glasses disconnected and the phone in airplane mode.

## 6. Build order

Each phase ends with: build, run tests, commit, a 2–3 line summary.

| # | Phase | Est. | Done when |
|---|---|---|---|
| 0 | Commit crossing-scan files. Access checks: MapKit walking route printed; one Vexcel ortho call; one Matterport model query. | 0.5 h | All three answer, or each failure is written down with its status code (never the key). |
| 1 | `RouteGeometry`, `NavigationEngine`, `LocationProvider`, GPX replay, unit tests. | 2 h | A replayed trace gives the right cues at the right distances. |
| 2 | `SpeechArbiter`, wired into `AppModel`. | 1 h | Scripted test: a hazard fired during a turn cue gives the right order and a fresh distance. |
| 3 | Button, `VoiceCommand`, `DestinationSearch`, confirmation flow, App Intent. | 1.5 h | A spoken request outdoors shows the right route on the debug panel and starts guidance. |
| 4 | Replay mode and nav debug panel. | 1 h | Full demo runs from replay in airplane mode. |
| 5 | Server: Vexcel crosswalks, Matterport blurb, phone client, tile view. **Cuttable.** | 1.5 h | Two real Princeton intersections show the right tile and detection; 403, empty and timeout each degrade quietly. |
| 6 | CLAUDE.md edits, record the demo GPX trace and clips, outdoor proof video. | 0.5 h | — |

The engine and arbiter come before voice, on purpose: they are testable at a desk and are the part judges hear. If time runs out after phase 4, the demo is complete without any server.

## 7. Tests

Pure unit tests, no device needed:

1. Snapping: a point 8 m beside the line maps to the right along-route distance.
2. Bearing change gives left, right, continue and turn-around at the right angles.
3. Feet rounding: 87 → 90, 149 → 150, 412 → 400.
4. Clock direction from heading and route bearing (12, 3, 6, 9 o'clock cases).
5. GPX trace around one block: Advance, Imminent and After-turn cues fire once each, in order, within ±30 ft of their targets.
6. Off-route for 9 s → no reroute. For 11 s → one reroute.
7. Leg shorter than 150 ft → no Advance cue.
8. Arbiter: level-3 hazard during an Advance cue → hazard speaks at once, the cue replays with a smaller distance.
9. Arbiter: the maneuver is passed during the hazard → the stale cue is dropped.
10. Arbiter: no navigation cue starts while a level is ≥ 2.
11. Command parser: "I want to go to McDonald's", "take me to the nearest coffee shop", "stop", and noise.
12. Intel client: `ok`, 403, empty, timeout and malformed JSON each produce the right phrase suffix (or none).
13. Server (pytest, Vexcel mocked): inside box, outside box, 403, 429, timeout.

## 8. Known limits (say these to judges, don't hide them)

- GPS is good to 5–10 m between buildings, so cues can come early or late. This is why cues are at ~150 ft and ~25 ft, not exact points.
- Aerial images are past captures. They show where a crosswalk is painted, not traffic or signals. Live danger is the hazard loop's job.
- Crossings that are not at a turn are not announced.
- No indoor navigation. Guidance ends at the building.
- The clock-direction cue depends on a compass that is unreliable in a pocket.
- The screen must stay on; a locked phone is not supported.

## 9. Open items

1. **Demo phone model.** The Action button needs iPhone 15 Pro or newer. On an older phone, Back Tap is the binding, and it is unreliable through a pocket.
2. **Keys.** Put them in `server/.env` (copy the names from the bundle's `.env.example`). Do not send them in chat.
3. **Bluetooth mic vs camera stream** (5.2) is untested.
4. **Is the GitHub repo public?** If so, check that nothing from rule 7 has been pushed, including this folder.
5. Ask the CoStar reps whether "Vexcel plus one Matterport metadata call" counts as two layers.

## 10. Phase 0 results (2026-11-14)

Run with `SSL_CERT_FILE=/etc/ssl/cert.pem python3 server/access_check.py` (this Mac's Python has no certificate bundle of its own).

| Check | Result |
|---|---|
| MapKit search + walking route from Nassau Hall | Works. 22 results for "McDonald's"; routes return steps, distances and a polyline. |
| Vexcel `POST /ortho/extract`, 80 m square in Princeton | 200, `image/jpeg`, 0.7 s. Imagery dated 08/2026. |
| Matterport `model(id:)` query | 200. 3 floors, 32 rooms, 66 scan points. |

Consequences for the build:

1. **The nearest McDonald's is about 4.5 miles away (108 minutes on foot).** Use it for the voice search and the route screen only. The walked demo needs a destination a few hundred feet away.
2. **The Matterport model returns no `geolocation`.** The arrival blurb cannot match by the model's own position. The server takes the building's latitude and longitude from `server/.env` (`MATTERPORT_MODEL_LAT`, `MATTERPORT_MODEL_LON`, values from the event's model index) instead.
3. MapKit step text is inconsistent ("Take a right", "Take a slight left turn", "Walk over the bridge"). This confirms the rule in 5.4: derive left and right from geometry, not from the text.
4. `/elements/detect` for crosswalks is still untested. It is tested in build phase 5.
