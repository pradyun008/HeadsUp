import Foundation

/// Wire protocol shared with the wristband firmware.
enum BandConstants {
  /// Peripheral name the app scans for.
  static let peripheralName = "HapticBand"

  // TODO: match the band firmware
  static let serviceUUID = "0000FFE0-0000-1000-8000-00805F9B34FB"
  // TODO: match the band firmware
  static let levelsCharacteristicUUID = "0000FFE1-0000-1000-8000-00805F9B34FB"

  /// The app writes `[leftLevel, rightLevel]` (each 0–3) this often, even when nothing changed.
  static let heartbeatInterval: TimeInterval = 0.2
  /// The firmware turns both motors off if it hears nothing for this long.
  static let firmwareTimeout: TimeInterval = 0.6
}
