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

final class FocalTestTests: XCTestCase {
  // A 6 ft (1.829 m) person whose box is 0.366 of the frame at 3 m gives f = 0.6.
  func testFocalLengthFromOneReading() {
    XCTAssertEqual(FocalTest.focalLength(boxHeight: 0.3658, distance: 3, personHeight: 1.8288), 0.6, accuracy: 0.001)
    // The same camera at 5 m and 7 m: the box shrinks, the focal length does not change.
    XCTAssertEqual(FocalTest.focalLength(boxHeight: 0.2195, distance: 5, personHeight: 1.8288), 0.6, accuracy: 0.001)
    XCTAssertEqual(FocalTest.focalLength(boxHeight: 0.1568, distance: 7, personHeight: 1.8288), 0.6, accuracy: 0.001)
  }

  func testAverageAndSpread() {
    let result = FocalTest.average([0.60, 0.62, 0.58])!
    XCTAssertEqual(result.mean, 0.60, accuracy: 0.0001)
    XCTAssertEqual(result.spread, 0.0667, accuracy: 0.001)
    XCTAssertNil(FocalTest.average([]))
  }

  // The measured focal length must give back the taped distance for the same box.
  func testMeasuredFocalLengthReproducesTheDistance() {
    let f = FocalTest.focalLength(boxHeight: 0.25, distance: 5, personHeight: 1.7)
    let distance = RiskEstimator.distance(objectClass: .person, top: 0.3, bottom: 0.55, focalLength: f)
    XCTAssertEqual(distance?.metres ?? 0, 5, accuracy: 0.01)
  }
}
