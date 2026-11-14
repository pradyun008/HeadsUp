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
    shift: (Double) -> Double = { _ in 0 }, wearer: WearerMotion = .stationary,
    detections: (Double) -> [Detection]
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
      steps.append(Step(time: t, frame: estimator.update(tracks: tracks, time: t, frameShift: frameShift, wearer: wearer)))
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

  func testCoastingTrackHoldsItsJudgmentWithTauCountingDown() {
    // Person at level 2 disappears (occluded): the judgment is held while the track coasts, and
    // its tau counts down by the time passed (the object is assumed to keep its speed).
    let steps = run(duration: 8.8) { t in t < 7.5 ? Scenario.walksToward.detections(at: t) : [] }
    let beforeStep = steps.last { $0.time < 7.5 }!
    let before = beforeStep.only!
    XCTAssertGreaterThanOrEqual(before.level, 2)
    let coastingStep = steps.first { $0.time > 8.0 }!
    let coasting = coastingStep.only!
    XCTAssertEqual(coasting.held, true)
    XCTAssertEqual(coasting.state, .onCourse)
    XCTAssertEqual(coasting.tau!, max(0.05, before.tau! - (coastingStep.time - beforeStep.time)), accuracy: 1e-6)
    XCTAssertGreaterThanOrEqual(coasting.level, before.level)
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

  // Distance from box height: focal length × typical height ÷ box height.
  func testDistanceFromBoxHeight() {
    // Person (1.7 m), f = 0.6 frame heights, box 0.34 frame heights tall → 0.6 × 1.7 / 0.34 = 3.0 m.
    let person = RiskEstimator.distance(objectClass: .person, top: 0.30, bottom: 0.64, focalLength: 0.6)
    XCTAssertEqual(person?.metres ?? 0, 3.0, accuracy: 1e-9)
    XCTAssertEqual(person?.reliable, true)
    // Half the box height → twice as far.
    let farther = RiskEstimator.distance(objectClass: .person, top: 0.40, bottom: 0.57, focalLength: 0.6)
    XCTAssertEqual(farther?.metres ?? 0, 6.0, accuracy: 1e-9)
    // Car (1.5 m), box 0.15 tall → 0.6 × 1.5 / 0.15 = 6.0 m.
    let car = RiskEstimator.distance(objectClass: .car, top: 0.45, bottom: 0.60, focalLength: 0.6)
    XCTAssertEqual(car?.metres ?? 0, 6.0, accuracy: 1e-9)
    // A box with no height has no distance.
    XCTAssertNil(RiskEstimator.distance(objectClass: .person, top: 0.5, bottom: 0.5, focalLength: 0.6))
  }

  // A box touching the top or bottom of the frame is cut off, so its distance is marked unreliable.
  func testCutOffBoxDistanceIsUnreliable() {
    XCTAssertEqual(RiskEstimator.distance(objectClass: .person, top: 0.0, bottom: 0.8, focalLength: 0.6)?.reliable, false)
    XCTAssertEqual(RiskEstimator.distance(objectClass: .person, top: 0.2, bottom: 1.0, focalLength: 0.6)?.reliable, false)
  }

  // Every tracked object gets a distance on every frame, including before it can be judged ("too new").
  func testEveryTrackGetsDistanceEveryFrame() {
    let detections: (Double) -> [Detection] = { _ in
      [Detection(objectClass: .person, confidence: 0.9, left: -0.1, right: 0.1, top: 0.30, bottom: 0.64),
       Detection(objectClass: .car, confidence: 0.9, left: 0.4, right: 0.8, top: 0.45, bottom: 0.60)]
    }
    let steps = run(duration: 1, detections: detections)
    for step in steps {
      XCTAssertEqual(step.frame.assessments.count, 2)
      for a in step.frame.assessments { XCTAssertNotNil(a.distance) }
    }
    // On the first frame nothing can be judged yet, but the distance is already there.
    XCTAssertTrue(steps[0].frame.assessments.allSatisfy { $0.state == .tooNew && $0.distance != nil })
  }

  // MARK: - "Is it moving?"

  /// A person centred in the frame at forward distance z(t), sized with the app's own constants
  /// (box height = focal length × 1.7 m ÷ distance). `cutOffTop` pins the box to the top edge.
  private func person(at z: Double, cutOffTop: Bool = false) -> Detection {
    let h = MeasuredConstants.focalLength * MeasuredConstants.typicalHeight(of: .person) / z
    let w = h * 0.4
    let top = cutOffTop ? 0.0 : 0.5 - h / 2
    return Detection(objectClass: .person, confidence: 0.9, left: -w / 2, right: w / 2, top: top, bottom: top + h)
  }

  // Wearer walks at 1.4 m/s toward a STANDING person → "walking into", never an alert.
  func testWalkingIntoStandingPersonIsSuppressed() {
    let steps = run(duration: 3.9, wearer: .walking(speed: 1.4, fromPace: true)) { t in [self.person(at: 8 - 1.4 * t)] }
    let judged = steps.compactMap(\.only).filter { $0.ownSpeed != nil }
    XCTAssertFalse(judged.isEmpty)
    XCTAssertEqual(steps.map(\.maxLevel).max(), 0)
    // Its own speed comes out near 0 (closing ≈ the wearer's 1.4 m/s).
    XCTAssertEqual(judged.last!.ownSpeed!, 0, accuracy: 0.3)
    XCTAssertEqual(judged.last!.state, .walkingInto)
    // Not suppressed on the very first judged frame: it takes several frames below the cutoff.
    XCTAssertEqual(judged.first!.state, .onCourse)
  }

  // Wearer walks at 1.4 m/s, a person walks at them at 1.4 m/s → own speed ≈ 1.4, alerts.
  func testPersonWalkingAtWalkingWearerAlerts() {
    let steps = run(duration: 2.3, wearer: .walking(speed: 1.4, fromPace: true)) { t in [self.person(at: 8 - 2.8 * t)] }
    XCTAssertGreaterThan(steps.map(\.maxLevel).max() ?? 0, 0)
    XCTAssertFalse(steps.compactMap(\.only).contains { $0.state == .walkingInto })
    let last = steps.compactMap(\.only).last { $0.ownSpeed != nil }!
    XCTAssertEqual(last.ownSpeed!, 1.4, accuracy: 0.3)
  }

  // Wearer standing still → anything growing on course counts as moving (behaviour as before).
  func testStationaryWearerKeepsOldBehaviour() {
    let steps = run(duration: 3.9) { t in [self.person(at: 8 - 1.4 * t)] }
    XCTAssertGreaterThan(steps.map(\.maxLevel).max() ?? 0, 0)
    XCTAssertFalse(steps.compactMap(\.only).contains { $0.state == .walkingInto })
    XCTAssertTrue(steps.allSatisfy { $0.frame.wearer == .stationary })
  }

  // A box cut off from its first frame never has a reliable distance → never suppressed (no misses).
  func testNeverReliableDistanceIsNotSuppressed() {
    let steps = run(duration: 3.9, wearer: .walking(speed: 1.4, fromPace: true)) { t in
      [self.person(at: 8 - 1.4 * t, cutOffTop: true)]
    }
    XCTAssertTrue(steps.compactMap(\.only).allSatisfy { !$0.distanceReliable })
    XCTAssertFalse(steps.compactMap(\.only).contains { $0.state == .walkingInto })
    XCTAssertGreaterThan(steps.map(\.maxLevel).max() ?? 0, 0)
  }

  // MARK: - Pauses, cut-off hold, jumps

  // Head scanning side to side for 2.6 s: judgment held (counting down) for the first 2 s, then
  // dropped to none; after the scan it is rebuilt from fresh sightings only.
  // (A car, so the box is wide enough for the tracker to keep its ID through the scan.)
  func testLongPauseDropsJudgmentThenRebuilds() {
    let scanStart = 2.0, scanEnd = 4.6
    // Triangle wave: 0.7 units/s (above the 0.5 unstable threshold), ±0.2.
    func offset(_ t: Double) -> Double {
      guard t > scanStart && t < scanEnd else { return 0 }
      let period = 4 * 0.2 / 0.7, phase = (t - scanStart).truncatingRemainder(dividingBy: period) / period
      return phase < 0.25 ? 0.8 * phase : phase < 0.75 ? 0.4 - 0.8 * phase : 0.8 * phase - 0.8
    }
    let steps = run(duration: 6.5, shift: offset) { t in
      let z = 20 - 2 * t, h = 0.6 * 1.5 / z, w = 2.5 * h, c = offset(t)
      return [Detection(objectClass: .car, confidence: 0.9, left: c - w / 2, right: c + w / 2,
                        top: 0.5 - h / 2, bottom: 0.5 + h / 2)]
    }
    XCTAssertTrue(steps.allSatisfy { $0.frame.assessments.count == 1 }, "one track throughout")
    let before = steps.last { $0.time < scanStart }!.only!
    XCTAssertEqual(before.state, .onCourse)
    let early = steps.filter { $0.time > scanStart + 0.1 && $0.time < scanStart + 1.9 }
    XCTAssertFalse(early.isEmpty)
    for step in early {
      XCTAssertTrue(step.frame.unstable, "t=\(step.time)")
      XCTAssertEqual(step.only?.held, true)
      XCTAssertEqual(step.only?.state, .onCourse, "t=\(step.time)")
    }
    // Counting down while held.
    XCTAssertLessThan(early.last!.only!.tau!, early.first!.only!.tau! - 1.5)
    let late = steps.filter { $0.time > scanStart + 2.1 && $0.time < scanEnd }
    XCTAssertFalse(late.isEmpty)
    for step in late {
      XCTAssertEqual(step.only?.state, .tooNew, "dropped, t=\(step.time)")
      XCTAssertEqual(step.only?.level, 0)
    }
    // Rebuilt after the scan settles, from fresh sightings.
    XCTAssertEqual(steps.last!.only?.state, .onCourse)
    XCTAssertEqual(steps.last!.only?.held, false)
  }

  // Walking at the camera until the box fills the frame at ~2.5 m. From then on the box is cut off
  // and stops growing (worst case: tau reads "not approaching"). The level never goes down while cut off.
  func testCutOffBoxLevelCannotGoDown() {
    func h(_ t: Double) -> Double { 2.5 / (6.5 - 1.4 * t) }
    let steps = run(duration: 4.1) { t in
      let cut = h(t) >= 1, height = min(1, h(t)), w = 0.5 * height
      return [Detection(objectClass: .person, confidence: 0.9, left: -w / 2, right: w / 2,
                        top: cut ? 0 : 0.5 - height / 2, bottom: cut ? 1 : 0.5 + height / 2)]
    }
    guard let firstCut = steps.firstIndex(where: { h($0.time) >= 1 }) else { return XCTFail("never cut off") }
    let levelBefore = steps[firstCut - 1].only!.level
    XCTAssertGreaterThanOrEqual(levelBefore, 2)
    for step in steps[firstCut...] {
      XCTAssertGreaterThanOrEqual(step.only!.level, levelBefore, "t=\(step.time)")
    }
    XCTAssertTrue(steps[firstCut...].contains { $0.only!.cutOffHold }, "the hold should have been needed")
  }

  // A standing person ahead (not growing) merges with someone into a 1.4× box that stays:
  // no false alarm (old and new sizes never mix) and no blind spot (judgment held, never blank).
  func testLastingMergeCausesNoFalseAlarmOrBlindSpot() {
    let steps = run(duration: 4) { t in
      let scale = t >= 2 ? 1.4 : 1.0
      let h = 0.6 * 1.7 / 5 * scale, w = 0.5 * h
      return [Detection(objectClass: .person, confidence: 0.9, left: -w / 2, right: w / 2,
                        top: 0.5 - h / 2, bottom: 0.5 + h / 2)]
    }
    XCTAssertEqual(steps.map(\.maxLevel).max(), 0)
    let firstJudged = steps.firstIndex { $0.only?.state != .tooNew }!
    XCTAssertTrue(steps[firstJudged...].allSatisfy { $0.only?.state != .tooNew }, "no blank judgment after the merge")
    XCTAssertTrue(steps.contains { $0.only?.held == true && $0.time >= 2 }, "held during the check")
  }
}
