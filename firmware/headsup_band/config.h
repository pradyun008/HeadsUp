#pragma once
#include <stdint.h>

// Central band configuration: DESIGN.md §§10, 13. Current ESP32 dev board.
namespace Config {
constexpr uint8_t leftMotorPin = 26;
constexpr uint8_t rightMotorPin = 27;
constexpr uint8_t buttonPin = 13;
// LEDs share motor pins in this build; they cannot be disabled separately.
constexpr uint32_t pwmFrequency = 20000; // Hz
constexpr uint8_t pwmResolution = 8; // bits
constexpr uint8_t motorStrength = 255;
constexpr uint32_t kickMs = 30;
constexpr uint32_t bandWatchdog = 600; // milliseconds (S2)
constexpr uint32_t slowOnMs = 150;
constexpr uint32_t slowOffMs = 350;
constexpr uint32_t fastOnMs = 100;
constexpr uint32_t fastOffMs = 100;
constexpr uint32_t debounceMs = 30;
constexpr uint32_t longPressMs = 1000;
constexpr uint32_t selfTestMs = 100;
constexpr uint32_t testLevelMs = 1000;
constexpr uint32_t batteryIntervalMs = 30000;
constexpr uint8_t protocolVersion = 0x01;
constexpr uint8_t commandLength = 6;
constexpr const char* serviceUUID = "7a1e0001-4c2b-4f5e-9b0a-2d1c3e4f5a60";
constexpr const char* commandUUID = "7a1e0002-4c2b-4f5e-9b0a-2d1c3e4f5a60";
constexpr const char* statusUUID = "7a1e0003-4c2b-4f5e-9b0a-2d1c3e4f5a60";
constexpr const char* deviceNamePrefix = "HeadsUp-";
}
static_assert(Config::bandWatchdog == 600, "S2 watchdog must remain 600 ms");
