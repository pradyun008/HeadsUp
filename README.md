# HeadsUp

Awareness aid for blind, low-vision and deafblind pedestrians. Meta glasses feed
an iPhone's offline perception loop; a two-motor ESP32 wrist band reports hazard
side and urgency. It supplements a white cane. It never gives permission to move.

Read [the specification](docs/DESIGN.md), [decisions](docs/DECISIONS.md), and
[test status](docs/TEST_RESULTS.md). Build milestones M0–M10 strictly in order.
The current scaffold is **M0 pending hardware validation**, not a working aid.

## M0 iPhone bring-up

Requires full Xcode with iOS SDK, a physical iPhone and signing credentials.
Install XcodeGen if unavailable (`brew install xcodegen`), then:

```sh
cd ios
cp Local.xcconfig.example Local.xcconfig
# Edit Local.xcconfig with your development team and unique bundle identifier.
xcodegen generate
open HeadsUp.xcodeproj
```

Local signing overrides are ignored by Git and survive project regeneration.
In Xcode select the physical iPhone. Build and run the HeadsUp scheme. Confirm the M0 bring-up screen appears.
Record device, OS, command/build result and date in `docs/TEST_RESULTS.md`.
Generated Xcode projects are ignored; `ios/project.yml` is their source of truth.

## M0 band bring-up

Use Arduino IDE with Espressif ESP32 **3.x** core, select the exact board and USB
port, then open `firmware/headsup_band/headsup_band.ino`, compile and upload.
The current target is the ESP32 dev board in §13.5 (not the later XIAO variant).
Confirm both motor/LED outputs remain off. Record board/core version and upload
result. This scaffold has no BLE or alert functionality; those belong to M2.

Do not begin M1 until both M0 hardware checks pass. M1 uses Meta's official
CameraAccess sample and measures ≥10 fps for 60 seconds on the actual equipment.
Never substitute simulated results for physical acceptance tests.
