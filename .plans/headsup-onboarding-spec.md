# HeadsUp onboarding and Liquid Glass buttons

Added 2026-11-15 by Eric. Decisions: D-34, D-35 in `decision-log.md`.
Figma (Apple iOS 26 UI kit): https://www.figma.com/design/ouFti7poA50NCeBu3PjnW3/iOS-and-iPadOS-26--Community-?node-id=8417-2

## What it is

A five-slide first-run onboarding that introduces HeadsUp, shows what the band's two cues feel like, and hands off into the app. It is written for a caretaker setting the app up, or a wearer listening with VoiceOver, so every slide works when only heard.

It follows the hard rules in `CLAUDE.md`:
- Rule 1: nothing says anything is safe or tells the wearer what to do. The last slide uses the product line "HeadsUp tells you what's around you. You decide what to do."
- Rule 4: left and right are described as the camera sees them ("on the left of the camera's view … The camera turns with your head").
- The motors are named "left cue" and "right cue", as the Outputs section asks.

## Slides

| # | Kicker | Title | Body | Hero | Button tint |
| --- | --- | --- | --- | --- | --- |
| 1 | WELCOME | Meet HeadsUp | An awareness aid for blind and low-vision pedestrians. If you're setting it up for someone you care for, read along. Every screen also works with VoiceOver. | Glasses on a tinted glass disc, band disc beside it | Indigo |
| 2 | THE WRISTBAND · 1 OF 3 | Left cue | Something heading toward you on the left of the camera's view buzzes the left cue. The camera turns with your head. | Band, left pod at level 2 | Orange |
| 3 | THE WRISTBAND · 2 OF 3 | Right cue | Something heading toward you on the right of the camera's view buzzes the right cue. | Band, right pod at level 2 | Orange |
| 4 | THE WRISTBAND · 3 OF 3 | Both cues at once | Something straight ahead buzzes both cues. The closer it gets, the stronger and faster the buzz. | Three bands, both pods lit: Low, High, Urgent | Red |
| 5 | (none) | HeadsUp tells you what's around you. | You decide what to do. | Glasses disc | Mint ("Get started") |

Slide 4 matches `AlertPolicy`: AHEAD drives both sides, and the level names match the risk table (1 low, 2 high, 3 urgent).

## Look

- Black background with two or three soft colored glows in the top half (EllipticalGradient). Text sits on the black lower half for contrast. The glows drift slowly and hold still under Reduce Motion.
- Page dots above a full-width tinted Liquid Glass button. Glass back button (chevron.backward) from slide 2 on.
- Onboarding is always dark (`preferredColorScheme(.dark)`). The rest of the app still follows the system setting.

## Band picture (`WristbandIllustration`)

Each pod glows in its level's color (yellow 1, orange 2, red 3) and sends out pulse rings: one ring at level 1, two at 2, three at 3. Rings repeat at the phone-haptic fallback's periods (1.0, 0.6, 0.35 s), so the picture and the felt rhythm agree. Intensity shows on four channels at once: ring count, glow size, pulse speed and color, plus the words Low, High and Urgent, so it reads without color.

The slides do not drive the band or the phone haptics. Those belong to the hazard loop, and the band is still simulated (no BLE yet). When the real band lands, a follow-up could play the matching cue on slides 2 to 4.

Asset placeholder: `[ASSET: wristband-top.svg]` could replace the drawn strap and pods later. The pulse rings should stay procedural.

## Motion

| Moment | Animation |
| --- | --- |
| Next or back | Old slide fades out in 0.18 s; new slide rises 8 pt and fades in after 0.16 s, cubic-bezier(0.22, 1, 0.36, 1), 0.45 s. Glows crossfade. |
| Get started | Onboarding fades and grows to 104%; the tabs fade up 8 pt. 0.55 s, cubic-bezier(0.65, 0, 0.35, 1). |
| Reduce Motion | All transitions become a 0.15 s crossfade; glows and rings hold still. |

VoiceOver focus moves to each new slide's title. The page dots read as "Page 2 of 5". Each hero is one element with a short description, for example "Wristband. Left cue buzzing."

Completion is stored in `@AppStorage("hasCompletedOnboarding")`. To see the slides again, launch with the argument `-hasCompletedOnboarding NO`.

## Liquid Glass buttons (`VibrantGlassButtonStyle`)

The main action buttons use `.buttonStyle(.vibrantGlass(color))`: iOS 26 Liquid Glass tinted with a system color, a solid tinted capsule before iOS 26, and a plain solid fill under Reduce Transparency. Layout is unchanged; only the style changed.

| Screen | Button | Tint |
| --- | --- | --- |
| Main | Start / Stop | Green / Red |
| Main | Speak a destination | Indigo |
| Main | Stop navigation | Red (was bordered) |
| Main | Connect glasses in Meta AI | Blue (was bordered) |
| Debug | Start / Stop | Green / Red |
| Debug | Record | Orange (was bordered) |
| Route | Replay demo | Indigo |
| Route | Stop | Red (was bordered) |

The label color is chosen per tint, black or white, whichever has more contrast with the resolved tint in the current appearance. Measured on iOS 26.3 Simulator screenshots, every label is above the 4.5:1 WCAG minimum:

| Tint | Light mode | Dark mode |
| --- | --- | --- |
| Green | black 9.4:1 | black 10.4:1 |
| Red | black 5.9:1 | black 6.0:1 |
| Indigo | white 5.1:1 | black 5.7:1 |
| Blue | black 6.0:1 | black 6.4:1 |
| Orange | black 9.0:1 | black 9.3:1 |

The glass is a background behind the label, never `.interactive()` glass on the label itself, which would take the tap.

## Verified

- Builds for the iOS 26.3 Simulator (Xcode 26.3, unsigned).
- All five slides rendered and checked in the Simulator.
- In an unsigned Simulator build, `Wearables.configure()` fails, so after onboarding the app shows its existing "Meta glasses SDK failed to start" message. That is not caused by this change and needs a signed build to check the restyled tabs on a phone.
