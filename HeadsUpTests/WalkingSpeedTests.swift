import XCTest
@testable import HeadsUp

/// The rules that turn phone activity labels and pace readings into the wearer's motion.
final class WalkingSpeedTests: XCTestCase {
  // No activity reading yet (startup) → stationary: subtract nothing, so nothing is hidden.
  func testStartsStationary() {
    XCTAssertEqual(WalkingSpeedEstimator().current, .stationary)
  }

  // Walking with no pace reading yet → the cautious default speed.
  func testWalkingWithoutPaceUsesDefault() {
    var e = WalkingSpeedEstimator()
    e.activityChanged(.walking)
    XCTAssertEqual(e.current, .walking(speed: MeasuredConstants.defaultWalkingSpeed, fromPace: false))
  }

  // Pace is seconds per metre, so speed = 1 ÷ pace. The last reading is held.
  func testPaceBecomesSpeed() {
    var e = WalkingSpeedEstimator()
    e.activityChanged(.walking)
    e.paceReading(secondsPerMetre: 0.8)
    XCTAssertEqual(e.current, .walking(speed: 1.25, fromPace: true))
    e.paceReading(secondsPerMetre: nil)  // a reading with no pace keeps the last one
    XCTAssertEqual(e.current, .walking(speed: 1.25, fromPace: true))
  }

  // Stopping → stationary at once; the next walk starts on the default until a fresh pace.
  func testStoppingResetsToStationaryThenDefault() {
    var e = WalkingSpeedEstimator()
    e.activityChanged(.walking)
    e.paceReading(secondsPerMetre: 0.8)
    e.activityChanged(.stationary)
    XCTAssertEqual(e.current, .stationary)
    e.paceReading(secondsPerMetre: 0.5)  // a late pace while stationary is ignored
    e.activityChanged(.walking)
    XCTAssertEqual(e.current, .walking(speed: MeasuredConstants.defaultWalkingSpeed, fromPace: false))
  }

  // Cycling, driving or unknown → treated as stationary (pedometer pace means nothing there).
  func testUnknownActivityIsStationary() {
    var e = WalkingSpeedEstimator()
    e.activityChanged(.walking)
    e.activityChanged(.unknown)
    XCTAssertEqual(e.current, .stationary)
  }
}
