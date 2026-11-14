# HeadsUp decision log

One entry per decision, grouped by component. Newest entries go at the bottom of each section.

**Status:** `Decided` = agreed by the team · `Proposed` = suggested, not yet confirmed · `Open` = still to decide · `Superseded` = replaced (link the replacement).

Related docs: `CLAUDE.md` (master design), `.plans/headsup-mvp-spec.md` (Roman's MVP spec), `HeadsUp Handoff Summary.pdf` (team handoff, Nov 14), `HeadsUp Coming-Toward Study Guide.pdf` (Q3 study guide).

Entry template:

```
### D-XX · Short title
- Date: YYYY-MM-DD · Status: Decided | Proposed | Open · By: name
- Decision: what we chose
- Why: the reason
- Alternatives considered: what we didn't pick and why
- Affects: files or components
```

---

## Product scope

### D-01 · Warn about things moving toward the wearer, not things the wearer walks into
- Date: 2026-11-13 · Status: Decided · By: Pradyun
- Decision: HeadsUp focuses on objects actively moving toward the wearer. Stationary objects the wearer walks toward should not alert (or only very late).
- Why: Matches the product line in `CLAUDE.md` ("the cane handles static obstacles, HeadsUp handles moving things") and cuts alert overload in crowds. Roman's current logic can't tell the two apart.
- Alternatives considered: warn on both equally; warn on both with moving ones prioritized.
- Affects: Prediction (new Q3), Prioritization.

### D-02 · Spoken output reports hazards, never instructions
- Date: 2026-11-11 · Status: Decided (from `CLAUDE.md` rule 1) · By: Roman
- Decision: Cues say what was seen ("bike, left"), never what to do ("move right") or that something is safe.
- Why: Safety and liability; the user decides.
- Alternatives considered: spoken recommendations ("step right"). Raised by Pradyun on 2026-11-13; conflicts with this rule and with the time budget (a sentence takes ~2 s). Not adopted.
- Affects: AlertPolicy, SpeechOutput.

## Architecture

### D-03 · All processing on the iPhone, no laptop or cloud in the hazard loop
- Date: 2026-11-13 · Status: Decided · By: team (`CLAUDE.md` rule 2, handoff PDF)
- Decision: Glasses → iPhone (DAT) → YOLO, tracking and risk on-device → speech/band. Cloud models may only refine estimates in the background and never block an alert.
- Why: A network round trip adds latency and depends on venue Wi-Fi. Roman's iOS app already does this.
- Alternatives considered: thin iPhone app relaying frames to a Python laptop over WebSocket (faster to iterate, worse latency, Wi-Fi risk).
- Affects: whole pipeline.

### D-04 · Pipeline framed as four systems
- Date: 2026-11-13 · Status: Decided · By: Pradyun
- Decision: 1 Detect (YOLO + tracker) → 2 Predict ("is it going to hit me?", Q1–Q4) → 3 Prioritize → 4 Output.
- Why: Clear ownership; the rework touches mainly Predict and Prioritize.
- Affects: planning only.

## 1 · Detect (Detector, Tracker)

### D-05 · Keep YOLO11n detection as built
- Date: 2026-11-13 · Status: Decided · By: Pradyun
- Decision: Keep the YOLO11n Core ML detector and the class filter (person, bicycle, motorcycle, car, bus, truck). Detection accuracy doesn't depend on who is moving, so it needs no change for D-01.
- Why: Buildings, walls and poles never become boxes, so they never reach prediction.
- Affects: `HeadsUp/Core/Detector.swift`, `HeadsUp/Core/Detection.swift`.

### D-06 · Add dogs to the kept classes?
- Date: 2026-11-14 · Status: Open
- Note: the handoff PDF lists dogs; Roman's code doesn't.
- Affects: `Detection.swift` (`ObjectClass`).

### D-07 · Check the portrait-to-square stretch
- Date: 2026-11-14 · Status: Open
- Note: the 360×640 stream is stretched to YOLO's square input (`.scaleFill`), so objects look ~1.8× wider than in training. Test detection counts on a recorded clip with stretch vs letterbox.
- Affects: `Detector.swift`.

### D-08 · Tracker: IoU tracker now, Kalman smoothing later
- Date: 2026-11-14 · Status: Proposed
- Note: the handoff PDF adds a Kalman filter on ln(size) and its rate. Also check ID swaps in crowds.
- Affects: `HeadsUp/Core/Tracker.swift`.

## 2 · Predict (RiskEstimator)

### D-09 · Keep Q1 (box growth → tau) as built
- Date: 2026-11-13 · Status: Decided
- Decision: Expansion rate k = slope of ln(sqrt(area)); tau = 1/k. Needs no distance.
- Affects: `RiskEstimator.swift`.

### D-10 · Keep Roman's head-turn handling
- Date: 2026-11-14 · Status: Proposed
- Decision: Keep subtracting the global image shift and pausing judgment during fast head turns. The handoff PDF doesn't cover head turns.
- Affects: `RiskEstimator.swift`, `HeadMotionEstimator.swift`.

### D-11 · Q2 on-course check: fixed strip or box-width rule?
- Date: 2026-11-14 · Status: Open
- Options: Roman's fixed ±0.15 image-width strip; or the handoff PDF's rule (predicted miss < about one box width, distance cancels, adapts to near/far objects).
- Affects: `RiskEstimator.swift`.

### D-12 · Add Q3 "is it moving at me?": its own speed = expansion × distance − my speed
- Date: 2026-11-13 · Status: Decided (approach) · By: Pradyun
- Decision: closing speed = expansion rate × distance; its own speed = closing speed − wearer speed. Positive above the cutoff = moving toward me; ~0 = stationary; negative = moving away.
- Why: Expansion alone can't separate "I'm walking into it" from "it's coming at me" (same tau, one measurement with two unknowns).
- Affects: `RiskEstimator.swift` (new), `AppModel.swift` (pedometer input).

### D-13 · Distance from typical size, with measured focal length
- Date: 2026-11-14 · Status: Decided (first version)
- Decision: distance = f × real height ÷ box height (person 1.7 m by height; car 1.8 m by width). f is measured with a tape test at 3/5/7 m on the demo stream resolution, not taken from specs.
- Why: No reliable published focal length for the Gen 3 glasses, and the DAT stream is scaled/cropped.
- Known errors: ±20–30%; kids, sitting people and cut-off boxes look farther away → false "moving" alerts.
- Alternatives considered: monocular depth model; ground comparison (see D-17).
- Update 2026-11-14 (Pradyun, implemented): measured values live in `HeadsUp/Core/MeasuredConstants.swift` (focal length in frame heights, placeholder 0.6 until the tape test; typical HEIGHT for every class: person 1.7, bicycle 1.05, motorcycle 1.15, car 1.5, bus 3.1, truck 2.5 m). Height for all classes because it stays steady across viewpoints. Distance is computed for every tracked object every frame and shown on the debug screen; boxes touching the top/bottom frame edge are marked unreliable.

### D-14 · Wearer speed from the iPhone pedometer
- Date: 2026-11-14 · Status: Proposed
- Decision: speed = cadence × calibrated step length (walk 20 m, count steps), per the handoff PDF.
- Known issue: lags starts and stops.
- Update 2026-11-14 (Pradyun, implemented): activity label first (stationary or unknown → speed math skipped); walking → 1 ÷ pace, last reading held; walking without a pace reading yet → default 1.0 m/s (`MeasuredConstants.defaultWalkingSpeed`, kept low because overestimating the wearer's speed hides real movers). Calibrated step length not used. Code: `HeadsUp/Core/WalkingSpeed.swift`.

### D-15 · Standing-still shortcut
- Date: 2026-11-14 · Status: Proposed
- Decision: when the pedometer says not walking, any on-course looming object counts as moving toward the wearer. No distance needed. Candidate to build first.
- Update 2026-11-14 (Pradyun, implemented): stationary wearer → anything growing on course counts as moving; no speed math.

### D-16 · Q3 speed cutoff
- Date: 2026-11-14 · Status: Open
- Options: 0.7 m/s everywhere (handoff PDF); or ~1.5 m/s while walking and 0.7 m/s while standing (suggested, because oncoming walkers flicker around 0.7 with ±30% error).
- Product question behind it: should an oncoming walker alert while the wearer is walking?
- Update 2026-11-14 (Pradyun, decided + implemented): 1.0 m/s while walking, as a middle between 0.7 and 1.5. Stored in `MeasuredConstants.movingCutoff` (not Settings), with the other guesses. An object switches to "walking into" (level 0) after 3 frames in a row below the cutoff and back to moving immediately.

### D-17 · Ground comparison as a stretch goal
- Date: 2026-11-14 · Status: Proposed
- Decision: compare the object's expansion with the ground at its feet (optical flow). Needs no distance or pedometer; struggles on plain pavement and in crowds.

### D-18 · Angle correction for wearer speed
- Date: 2026-11-14 · Status: Superseded (2026-11-14, see correction below)
- Original proposal: angle = atan(x × 180 ÷ f); subtract wearer speed × cos(object angle).
- Correction: the known-size formula gives forward distance Z (along the camera axis), not straight-line distance, and expansion rate measures how fast Z shrinks. Walking straight ahead shrinks Z for every standing object at exactly the wearer's speed, whatever its angle. So no cos(object angle) term is needed: its own speed = expansion × Z − wearer speed. A cos term only applies for the angle between head direction and walking direction (assumed 0 for the prototype).

### D-19 · Safeguards from the handoff PDF
- Date: 2026-11-14 · Status: Proposed
- Decision: require Q3 to hold for 3–5 frames; confidence check (tau from width vs height disagree > 50% → don't escalate); optional tau-rate check for braking/speeding up.

## 3 · Prioritize (AlertPolicy)

### D-20 · Pass/fail first, then rank by urgency
- Date: 2026-11-13 · Status: Decided (approach) · By: Pradyun
- Decision: only objects that pass Q1–Q4 are ranked. Rank by urgency (tau), not raw speed, so a close slow object can outrank a far fast one. #1 gets the spoken cue; the band still shows the max level per side.
- Why: Speech can say one thing at a time. Today ties at the same level go to the newest object.
- Open: exact score (tau only, or class danger × its speed ÷ tau).
- Affects: `HeadsUp/Core/AlertPolicy.swift`.

## 4 · Output (Speech, band, haptics)

### D-21 · Level thresholds: 2.5 s or 2 s for level 2?
- Date: 2026-11-14 · Status: Open
- Note: Roman's code uses 4 / 2.5 / 1.5 s; the handoff PDF uses 4 / 2 / 1.5 s.

## Repo and process

### D-22 · `main` branch created and set as default
- Date: 2026-11-13 · Status: Decided · By: Pradyun
- Decision: `main` created from `30e0164` and set as the GitHub default branch; personal branches (`pradyun`, `roman`) merge into it.

### D-23 · Every guess lives in the constants file
- Date: 2026-11-14 · Status: Decided · By: Pradyun
- Decision: `HeadsUp/Core/MeasuredConstants.swift` lists every number and logic assumption "Is it moving?" relies on, each marked PLACEHOLDER / GUESS / MEASURED with how to test it, so they can be measured later.
- Why: know exactly what we're guessing and improve accuracy one item at a time.
- Tradeoff: values there need an app rebuild to change (unlike Settings).

### D-24 · Cut-off boxes use the last reliable distance
- Date: 2026-11-14 · Status: Decided + implemented · By: Pradyun
- Decision: when a box is cut off by the frame, "Is it moving?" uses that object's last reliable distance; an object that never had one is never suppressed.
- Why: avoid missed hazards. A stale distance reads too far, which errs toward "moving" (toward warning).
