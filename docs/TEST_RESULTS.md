# Milestone and verification record

## 2026-11-14 — M0: IN PROGRESS, acceptance gate not passed

- Repository: Eric branch; specification saved verbatim in DESIGN.md.
- PASS: `swiftc -typecheck ios/HeadsUp/Config/Config.swift` (Swift 6.1.2 host compiler).
- PASS: `clang++ -std=c++11 -x c++ -fsyntax-only` with config.h included (host header syntax only).
- PASS: `plutil -lint ios/HeadsUp/App/Info.plist`.
- PASS: `git diff --check`; saved DESIGN.md byte comparison against the original attachment.
- Independent review: Claude Sonnet 5.5 inspected the actual M0 files against specification sections 0, 4, 9, 10 and 18. No blocking findings. Corrected stale check text, persistent signing setup, explicit background-mode plist array, and redundant unused band heartbeat constant; documented remaining scaffold choices.
- NOT RUN: XcodeGen generation, iOS app build, firmware target build; syntax checks above do not establish target compatibility.
- iPhone build/run: NOT RUN. `xcodebuild -version` fails because the selected developer directory is `/Library/Developer/CommandLineTools`; no Xcode app is installed in /Applications. No iOS SDK/device build is available.
- Band compile/upload: NOT RUN. Arduino IDE is installed, but no `arduino-cli` or `pio` is on PATH, and `/dev/cu.*` shows only Bluetooth-Incoming-Port and debug-console; no band serial port is exposed.
- Required to pass M0: actual iPhone build/run and actual compile/flash of the ESP32 band, with hardware/tool versions recorded here.
- M1–M10: NOT STARTED; blocked by M0's unpassed hardware gate per DESIGN.md §0.2 and §18.

No performance, selectivity, safety, BLE or frame-rate acceptance results have been measured.
