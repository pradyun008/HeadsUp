import XCTest
@testable import HeadsUp

/// Risk maths on synthetic tracks: no camera, no detector.
final class RiskEstimatorTests: XCTestCase {
  struct Step {
    let time: Double
    let frame: RiskFrame
    var only: RiskAssessment? { frame.assessments.count == 1 ? frame.assessments[0] : nil }
    var maxLevel: Int { frame.assessments.map(\.level).max() ?? 0 }
  }

  /// Runs detections through the real tracker and risk estimator at 15 fps.
  private func run(
    duration: Double, fps: Double = 15, config: RiskConfig = RiskConfig(),
    shift: (Double) -> Double = { _ in 0 }, detections: (Double) -> [Detection]
  ) -> [Step] {
    var tracker = Tracker()
    var estimator = RiskEstimator()
    estimator.config = config
    var steps: [Step] = []
    var lastOffset = shift(0)
    for i in 0...Int(duration * fps) {
      let t = Double(i) / fps
      let offset = shift(t)
      let frameShift = offset - lastOffset
      lastOffset = offset
      let tracks = tracker.update(detections(t), at: t, frameShift: frameShift)
      steps.append(Step(time: t, frame: estimator.update(tracks: tracks, time: t, frameShift: frameShift)))
    }
    return steps
  }

  private func run(_ scenario: Scenario, duration: Double? = nil) -> [Step] {
    run(duration: duration ?? scenario.duration - 0.2, shift: scenario.contentOffset(at:), detections: scenario.detections(at:))
  }

  // 1. Object straight ahead, growing steadily → on course, level rises as tau drops, side AHEAD.
  func testStraightAheadIsOnCourseAndLevelRises() {
    let steps = run(.walksToward)
    let judged = steps.compactMap(\.only).filter { $0.state != .tooNew }
    XCTAssertFalse(judged.isEmpty)
    for a in judged {
      XCTAssertEqual(a.state, .onCourse)
      XCTAssertEqual(a.side, .ahead)
    }
    // Levels never go down while it keeps coming, and reach every level in order.
    let levels = judged.map(\.level)
    XCTAssertEqual(levels, levels.sorted())
    XCTAssertEqual(Set(levels), [0, 1, 2, 3])
    // The tau estimate tracks the true time-to-contact (distance / closing speed).
    for step in steps {
      guard let a = step.only, let tau = a.tau, a.state == .onCourse else { continue }
      let trueTau = (12 - 1.4 * (step.time - 0.5)) / 1.4
      if trueTau > 0.8 && trueTau < 6 { XCTAssertEqual(tau, trueTau, accuracy: 0.25, "at t=\(step.time)") }
    }
  }

  // 2. Object slightly left, growing, staying put in the image (constant bearing) → on course, side LEFT.
  func testConstantBearingLeftIsOnCourseSideLeft() {
    let k = 0.4  // expansion rate → tau = 2.5 s
    let steps = run(duration: 2) { t in
      let half = 0.04 * exp(k * t)
      return [Detection(objectClass: .person, confidence: 0.9, left: -0.22 - half, right: -0.22 + half,
                        top: 0.5 - 2 * half, bottom: 0.5 + 2 * half)]
    }
    let last = steps.last!.only!
    XCTAssertEqual(last.state, .onCourse)
    XCTAssertEqual(last.side, .left)
    XCTAssertGreaterThanOrEqual(last.level, 1)
    XCTAssertEqual(last.tau!, 2.5, accuracy: 0.6)
  }

  // 3. Object growing but sliding toward the edge (passing at about 1 m) → passing, level 0.
  func testPassingAtOneMetreStaysLevelZero() {
    let steps = run(.walksPast)
    XCTAssertEqual(steps.map(\.maxLevel).max(), 0)
    let states = steps.compactMap { $0.only?.state }
    XCTAssertTrue(states.contains(.passing))
    XCTAssertFalse(states.contains(.onCourse))
    // Same on the other side.
    XCTAssertEqual(run(.demo, duration: 9.5).map(\.maxLevel).max(), 0)
  }

  // 4. Object not growing (someone walking across far away) → level 0.
  func testCrossingFarAwayIsLevelZero() {
    let steps = run(.crossesFar)
    XCTAssertEqual(steps.map(\.maxLevel).max(), 0)
    XCTAssertTrue(steps.compactMap { $0.only?.state }.contains(.notApproaching))
    XCTAssertFalse(steps.compactMap { $0.only?.state }.contains(.onCourse))
  }

  // 5. Object shrinking (moving away) → level 0.
  func testMovingAwayIsLevelZero() {
    let steps = run(.walksAway)
    XCTAssertEqual(steps.map(\.maxLevel).max(), 0)
    let states = Set(steps.compactMap { $0.only?.state })
    XCTAssertTrue(states.isSubset(of: [.tooNew, .notApproaching]))
  }

  // 6. A sudden global shift of every box (head turn) → frame unstable, levels held and not raised.
  func testHeadTurnMarksUnstableAndHoldsLevels() {
    // The person is at tau ≈ 3 s (level 1) when the wearer glances aside and back.
    var scenario = Scenario.walksToward
    scenario.headTurns = Scenario.glance(at: 6.0)
    let steps = run(scenario)

    let before = steps.last { $0.time < 6.0 }!
    XCTAssertFalse(before.frame.unstable)
    XCTAssertEqual(before.only?.level, 1)

    let during = steps.filter { $0.time > 6.05 && $0.time < 6.3 }
    XCTAssertFalse(during.isEmpty)
    for step in during {
      XCTAssertTrue(step.frame.unstable, "t=\(step.time)")
      XCTAssertEqual(step.only?.level, 1, "level must be held, t=\(step.time)")
      XCTAssertEqual(step.only?.held, true)
      XCTAssertEqual(step.only?.trackID, before.only?.trackID)
    }
    // Stable again well after the glance, and the judgment resumes.
    let after = steps.first { $0.time > 7.6 }!
    XCTAssertFalse(after.frame.unstable)
    XCTAssertEqual(after.only?.held, false)
    XCTAssertEqual(after.only?.state, .onCourse)
  }

  func testHeadTurnDoesNotRaisePassingObject() {
    // Someone passing 1 m to the right; the wearer glances toward them, which drags
    // their box into the middle of the frame. Level must stay 0 throughout.
    for shift in [-0.25, 0.25] {
      var scenario = Scenario.walksPast
      scenario.headTurns = Scenario.glance(at: 6.0, shift: shift)
      let steps = run(scenario)
      XCTAssertTrue(steps.contains { $0.frame.unstable })
      XCTAssertEqual(steps.map(\.maxLevel).max(), 0, "shift \(shift)")
    }
  }

  func testSlowHeadMotionIsNotUnstable() {
    // 0.2 units over 1 s = 0.2 units/s, under the 0.5 threshold.
    var scenario = Scenario.walksToward
    scenario.headTurns = [.init(start: 3, end: 4, shift: 0.2), .init(start: 5, end: 6, shift: -0.2)]
    XCTAssertFalse(run(scenario).contains { $0.frame.unstable })
  }

  func testBikeConvergingFromLeftIsOnCourseFromTheLeft() {
    let steps = run(.bikeFromLeft, duration: 4.4)
    let onCourse = steps.compactMap(\.only).filter { $0.state == .onCourse }
    XCTAssertFalse(onCourse.isEmpty)
    XCTAssertEqual(steps.map(\.maxLevel).max(), 3)
    XCTAssertTrue(onCourse.filter { $0.level >= 2 }.allSatisfy { $0.side == .left })
  }

  func testTooNewTrackIsNotJudged() {
    let steps = run(.walksToward, duration: 0.8)  // person appears at 0.5 s
    XCTAssertTrue(steps.compactMap(\.only).allSatisfy { $0.state == .tooNew && $0.level == 0 })
  }

  func testCoastingTrackHoldsItsLevel() {
    // Person at level 2 disappears (occluded): the level is held while the track coasts.
    let steps = run(duration: 8.8) { t in t < 7.5 ? Scenario.walksToward.detections(at: t) : [] }
    let before = steps.last { $0.time < 7.5 }!.only!
    XCTAssertGreaterThanOrEqual(before.level, 2)
    let coasting = steps.first { $0.time > 8.0 }!
    XCTAssertEqual(coasting.only?.level, before.level)
    XCTAssertEqual(coasting.only?.held, true)
    // Gone after the 1 s coast.
    XCTAssertTrue(steps.last!.frame.assessments.isEmpty)
  }

  /// Box jitter like a real detector's (±1.5% of box size on each edge), fixed seed.
  func testDemoCasesSurviveBoxJitter() {
    var seed: UInt64 = 42
    func noise() -> Double {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return (Double(seed >> 33) / Double(1 << 31) - 0.5) * 2  // −1…1
    }
    func jitter(_ dets: [Detection]) -> [Detection] {
      dets.map { d in
        var d = d
        let w = d.width * 0.015, h = d.height * 0.015
        d.left += noise() * w; d.right += noise() * w
        d.top += noise() * h; d.bottom += noise() * h
        return d
      }
    }
    let past = run(duration: 9.8) { jitter(Scenario.walksPast.detections(at: $0)) }
    XCTAssertEqual(past.map(\.maxLevel).max(), 0)
    let toward = run(duration: 9.8) { jitter(Scenario.walksToward.detections(at: $0)) }
    XCTAssertEqual(toward.map(\.maxLevel).max(), 3)
  }

  func testLevelThresholds() {
    let e = RiskEstimator()
    XCTAssertEqual(e.level(forTau: 5), 0)
    XCTAssertEqual(e.level(forTau: 3), 1)
    XCTAssertEqual(e.level(forTau: 2), 2)
    XCTAssertEqual(e.level(forTau: 1), 3)
  }
}
