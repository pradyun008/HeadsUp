import Foundation

/// Wire protocol shared with the wristband firmware (`arduino_backend/esp_bluetooth.ino`,
/// read 2026-11-15). The band is an ESP32 that advertises one service with one
/// writable characteristic and takes one command per motor.
enum BandConstants {
  /// The name the band advertises. The app finds it by its service, not by this name.
  static let peripheralName = "HeadsUp"

  /// Must match SERVICE_UUID in the firmware.
  static let serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
  /// Must match CHAR_UUID in the firmware. Written without response.
  static let commandCharacteristicUUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"

  /// The app sends both motors' commands this often, even when nothing changed.
  static let heartbeatInterval: TimeInterval = 0.2
  /// How long each command tells a motor to run. The firmware has no silence timeout, so this is
  /// what stops the motors if the app or the connection dies: a buzz ends this long after the
  /// last command. It must be longer than the heartbeat so a steady level feels continuous.
  static let buzzOnTime: TimeInterval = 0.4

  /// Motor strength (0–255) for each level 0–3.
  /// Chosen by estimate, then used in the 2026-11-15 test on the real band, which the team
  /// reported as working. Not tuned further: level 1 should be clearly felt, level 3 unmistakable.
  static let strengthForLevel: [UInt8] = [0, 90, 160, 255]

  /// The firmware's command for one motor: `[side, strength, on-time in 100 ms units]`.
  /// Side 0 is its "left" motor (pin D4), 1 its "right" motor (pin D10). Strength 0 stops it.
  static func command(motor: UInt8, level: UInt8) -> [UInt8] {
    let strength = strengthForLevel[Int(min(level, 3))]
    return [motor, strength, UInt8((buzzOnTime * 10).rounded())]
  }

  /// Both motors' commands for a level packet `[first motor level, second motor level]`.
  static func commands(forLevels packet: [UInt8]) -> [[UInt8]] {
    guard packet.count == 2 else { return [] }
    return [command(motor: 0, level: packet[0]), command(motor: 1, level: packet[1])]
  }
}
