import Foundation
import MWDATMockDevice

/// Simulated glasses from DAT's MockDeviceKit, so the glasses code path runs with no hardware.
/// The mock streams a bundled HEVC clip through the same session/camera APIs as real glasses.
@MainActor
enum MockGlassesController {
  static let defaultsKey = "useMockGlasses"
  private static var device: (any MockGlasses)?

  static var isEnabled: Bool { MockDeviceKit.shared.isEnabled }

  /// Returns an error message, or nil on success.
  @discardableResult
  static func enable() -> String? {
    guard device == nil else { return nil }
    // Starts registered with permissions granted, so no Meta AI app is needed.
    MockDeviceKit.shared.enable(config: MockDeviceKitConfig())
    do {
      let glasses = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
      if let feed = Bundle.main.url(forResource: "mock_feed", withExtension: "mp4") {
        glasses.services.camera.setCameraFeed(fileURL: feed)
      }
      // A device only becomes available once it is on and unfolded.
      glasses.powerOn()
      glasses.unfold()
      glasses.don()
      device = glasses
      return nil
    } catch {
      return "Mock glasses failed: \(error)"
    }
  }

  static func disable() {
    device = nil
    MockDeviceKit.shared.disable()
  }

  // Hooks for exercising error states by hand.
  static func fold() { device?.fold() }
  static func unfold() { device?.unfold() }
}
