# Implementation decisions

- 2026-11-14 — User confirmed that the attached M0–M10 sequence governs; M0–M18 in the original request was superseded.
- 2026-11-14 — Treat this repository root as `headsup/` in §9.1 rather than nesting another repository directory; preserves root agent instructions and normal project paths.
- 2026-11-14 — Camera HFOV has no specified default; represent it as nil until measured, never invent a calibration.
- 2026-11-14 — Use XcodeGen project.yml for a reproducible iOS 17 SwiftUI scaffold; full Xcode, signing and device validation remain required.
- 2026-11-14 — M0 band scaffold leaves outputs off; defer all BLE and pattern functionality to M2 per the milestone order.
- 2026-11-14 — M0 layout creates directories for later modules, not empty implementation files or a deployable backend template; those implementations remain gated by their milestones.
- 2026-11-14 — Keep optional component flags disabled in Config.swift per §0.2.5; additional band timings come from §13.4 and stay centralized in config.h.
- 2026-11-14 — Bluetooth central background mode follows §3.4. Use an explicit Info.plist array and camera/motion/Bluetooth permission descriptions; defer local-network permission until an actual integration requires it.
- 2026-11-14 — Use tracked Build.xcconfig with an optional ignored Local.xcconfig for signing/team and bundle ID overrides that survive generation; never store credentials.
- 2026-11-14 — M0 screen states disconnected status and the cane/coverage limitation; it produces no spoken or haptic output.
