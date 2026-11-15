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

/// Walking yes/no from the phone's shake: must react within about one window (1.5 s) both ways.
final class StepDetectorTests: XCTestCase {
  private let rate = 50.0  // samples per second, as on the phone

  /// Steps: about 2 bumps a second of `amplitude` g, plus small hand noise.
  private func walkingShake(_ t: Double, amplitude: Double = 0.03) -> Double {
    abs(amplitude * sin(2 * .pi * 1.8 * t)) + 0.005
  }

  /// Feeds `seconds` of samples starting at `start`; returns the first time `isWalking` changed.
  @discardableResult
  private func feed(
    _ d: inout StepDetector, from start: Double, seconds: Double, _ value: (Double) -> Double
  ) -> Double? {
    var changedAt: Double?
    for i in 0..<Int(seconds * rate) {
      let t = start + Double(i) / rate
      if d.add(acceleration: value(t), at: t), changedAt == nil { changedAt = t }
    }
    return changedAt
  }

  // Standing with the phone in hand (tiny tremor) never counts as walking.
  func testStandingStillIsNotWalking() {
    var d = StepDetector()
    feed(&d, from: 0, seconds: 10) { t in 0.007 + 0.002 * sin(t * 7) }
    XCTAssertFalse(d.isWalking)
    XCTAssertLessThan(d.wobble, MeasuredConstants.stepWobbleStop)
  }

  // Starting to walk is caught within about one window (Apple's label took ~10 s).
  func testStartingToWalkIsCaughtWithinTwoSeconds() {
    var d = StepDetector()
    feed(&d, from: 0, seconds: 5) { _ in 0.007 }
    let switched = feed(&d, from: 5, seconds: 5) { self.walkingShake($0) }
    XCTAssertTrue(d.isWalking)
    XCTAssertNotNil(switched)
    XCTAssertLessThan((switched ?? 99) - 5, 2.0)
  }

  // Stopping is caught within about one window too: the dangerous direction, because walking
  // speed subtracted while standing still can hide a real mover.
  func testStoppingIsCaughtWithinTwoSeconds() {
    var d = StepDetector()
    feed(&d, from: 0, seconds: 5) { self.walkingShake($0) }
    XCTAssertTrue(d.isWalking)
    let switched = feed(&d, from: 5, seconds: 5) { _ in 0.007 }
    XCTAssertFalse(d.isWalking)
    XCTAssertLessThan((switched ?? 99) - 5, 2.0)
  }

  // No flicker between steps while walking steadily.
  func testSteadyWalkingDoesNotFlicker() {
    var d = StepDetector()
    feed(&d, from: 0, seconds: 3) { self.walkingShake($0) }
    let flicker = feed(&d, from: 3, seconds: 10) { self.walkingShake($0) }
    XCTAssertNil(flicker)
    XCTAssertTrue(d.isWalking)
  }

  // Shake hovering between the two lines keeps whatever the label was: no flipping.
  func testShakeBetweenTheLinesDoesNotFlip() {
    var d = StepDetector()
    feed(&d, from: 0, seconds: 5) { _ in 0.013 }  // from standing: stays stationary
    XCTAssertFalse(d.isWalking)
    feed(&d, from: 5, seconds: 5) { self.walkingShake($0) }
    XCTAssertTrue(d.isWalking)
    let flipped = feed(&d, from: 10, seconds: 5) { _ in 0.013 }  // from walking: stays walking
    XCTAssertNil(flipped)
    XCTAssertTrue(d.isWalking)
  }

  // Just started: until the window has filled once, stay stationary even when shaking.
  func testNoDecisionBeforeTheWindowFills() {
    var d = StepDetector()
    feed(&d, from: 0, seconds: 0.5) { self.walkingShake($0) }
    XCTAssertFalse(d.isWalking)
  }
}
