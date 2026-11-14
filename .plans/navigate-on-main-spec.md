# Navigation on top of main's "Is it moving?" logic — spec

Date: 2026-11-14. From an interview with Roman after reading `origin/main` (commits `f5ee78d`, `84cbc7b`, Pradyun). Companion to `headsup-navigate-spec.md`; main's own reasoning is in `decision-log.md`.

## 1. What main added to the hazard loop

Before, anything growing on a collision course alerted, including a standing person the wearer walks toward. Main separates the two cases:

| Piece | What it does | File |
|---|---|---|
| Expansion rate → tau | Unchanged. Box growth gives time to contact. | `RiskEstimator.swift` |
| Distance | Focal length × typical height ÷ box height. | `RiskEstimator.swift`, `MeasuredConstants.swift` |
| Wearer speed | Phone activity label and pedometer pace. Walking with no pace reading yet uses 1.0 m/s. | `WalkingSpeed.swift` |
| "Is it moving?" | Object's own speed = distance ÷ tau − wearer speed. Below 1.0 m/s for 3 frames → state `walkingInto`, level 0. Wearer standing still → everything on course counts as moving. | `RiskEstimator.swift` |
| Jump check | A Kalman filter flags sudden box-size jumps and keeps them out of the tau fit. | `SizeFilter.swift`, `Tracker.swift` |
| Cut-off hold | A box touching the frame edge cannot drop in level. | `RiskEstimator.swift` |
| Paused countdown | A held judgment counts tau down; dropped after 2 s. | `RiskEstimator.swift` |
| Ranking | Most urgent object (lowest tau) speaks first. | `AlertPolicy.swift` |

So the app now marks only objects moving toward the wearer, and still relies on box expansion rate for timing.

## 2. Decisions

| # | Decision |
|---|---|
| 1 | **Merge main into roman now.** Done in `b12bb31`. Navigation is built on main's hazard logic from here on. |
| 2 | **Navigation does not feed GPS speed to the hazard check.** Wearer speed stays pedometer-only, as on main. GPS speed between buildings is noisy and lags, and a wearer speed that reads too high hides real movers. |
| 3 | **Replay demo uses the real pedometer.** The wearer stands at the table, so the hazard check sees "stationary" and a teammate walking at them alerts. The replayed GPS walk drives navigation only. No fake wearer motion, no debug toggle. |
| 4 | **Hazard speech stays** (answers main's open D-29). "bike, left" still interrupts navigation speech. Navigation is voice-only, so speech cannot be removed. |

## 3. How the two fit together

- Navigation code does not touch `RiskEstimator`, `Tracker`, `AlertPolicy`, `WalkingSpeed` or `MeasuredConstants`.
- The only shared points are in `AppModel`: the hazard level goes to the speech arbiter, and a hazard cue of level 2 or 3 closes the microphone.
- Hazard cues still carry their level as priority, so the arbiter's ranks (level 3 → 5, level 2 → 4) are unchanged by main's tau ranking. Main's ordering decides which hazard is spoken first; the arbiter decides hazard against navigation.
- The merged Xcode project is main's file plus the navigation files added by `tools/sync_xcodeproj.py`.

## 4. Consequences to know about

1. **The table demo cannot show "walking into a standing person stays quiet".** With a stationary wearer, main alerts on everything on course (decision 3). Showing the suppression needs a real walk, or a recorded clip run through the clip harness.
2. **The focal length is still a placeholder (0.6).** Until the tape test in `MeasuredConstants.swift` is done, distances, and so the walking-into judgment, are not trustworthy while the wearer walks. This matters for the outdoor proof video, where the wearer really walks.
3. **On a live navigated walk, a person standing in the route is not announced** once main judges them as walked-into. That is main's D-01 (the cane's job), and navigation does not change it.
4. **New permission prompt.** Main adds Motion & Fitness. With navigation's location, microphone and speech recognition, a fresh install now asks four times. Grant them all before the demo.

## 5. Verification

- Full suite after the merge: 122 tests, 1 skipped, 0 failures (simulator, 2026-11-14).
- Not verified: anything on a phone or the glasses. Main's logic and navigation have not run together on a device.

## 6. Open

- Tape test for the focal length (main's D-13), before any walking demo.
- Tell Pradyun that D-29 is answered (speech stays) and that `roman` now contains main.
