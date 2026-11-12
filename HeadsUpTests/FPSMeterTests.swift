import XCTest
@testable import HeadsUp

final class FPSMeterTests: XCTestCase {
  func testSteadyFifteenFps() {
    var meter = FPSMeter()
    var fps = 0.0
    for i in 0..<45 { fps = meter.tick(at: Double(i) / 15.0) }
    XCTAssertEqual(fps, 15, accuracy: 0.5)
  }

  func testSingleFrameIsZero() {
    var meter = FPSMeter()
    XCTAssertEqual(meter.tick(at: 10), 0)
  }

  func testResetForgetsHistory() {
    var meter = FPSMeter()
    _ = meter.tick(at: 0)
    _ = meter.tick(at: 0.1)
    meter.reset()
    XCTAssertEqual(meter.tick(at: 0.2), 0)
  }
}
