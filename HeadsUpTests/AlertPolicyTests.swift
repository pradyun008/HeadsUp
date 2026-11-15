import XCTest
@testable import HeadsUp

final class AlertPolicyTests: XCTestCase {
  private func track(_ id: Int, _ cls: ObjectClass = .person) -> Track {
    Track(id: id, objectClass: cls, confidence: 0.9, observations: [], left: -0.1, right: 0.1, top: 0.4, bottom: 0.8,
          lastSeen: 0, isCoasting: false, hits: 10)
  }

  private func frame(_ items: [(id: Int, level: Int, side: Side)]) -> RiskFrame {
    RiskFrame(assessments: items.map {
      RiskAssessment(trackID: $0.id, state: $0.level > 0 ? .onCourse : .passing, tau: 2, level: $0.level, side: $0.side)
    })
  }

  /// Feeds a sequence of raw levels for one track; returns the state after each frame.
  private func feed(_ policy: inout AlertPolicy, levels: [Int], side: Side = .ahead, cls: ObjectClass = .person,
                    id: Int = 1, startTime: Double = 0) -> [AlertState] {
    levels.enumerated().map { i, level in
      policy.update(risk: frame([(id, level, side)]), tracks: [track(id, cls)], time: startTime + Double(i) / 15)
    }
  }

  // 7. Hysteresis: a one-frame spike to level 3 does not change the output.
  func testOneFrameSpikeDoesNotChangeOutput() {
    var policy = AlertPolicy()
    let states = feed(&policy, levels: [0, 0, 0, 3, 0, 0, 0, 0, 0])
    for s in states {
      XCTAssertEqual(s.leftLevel, 0)
      XCTAssertEqual(s.rightLevel, 0)
      XCTAssertTrue(s.cues.isEmpty)
    }
    // Same from a non-zero level: a spike from 1 to 3 leaves it at 1.
    var policy2 = AlertPolicy()
    let states2 = feed(&policy2, levels: [1, 1, 1, 3, 1, 1, 3, 3, 1, 1])
    XCTAssertEqual(states2.dropFirst(2).map(\.leftLevel), Array(repeating: 1, count: 8))
  }

  func testThreeFramesToGoUp() {
    var policy = AlertPolicy()
    let states = feed(&policy, levels: [2, 2, 2, 2])
    XCTAssertEqual(states.map(\.leftLevel), [0, 0, 2, 2])
  }

  func testRisesOnlyToTheLevelThatHeld() {
    var policy = AlertPolicy()
    let states = feed(&policy, levels: [1, 3, 2, 3, 3, 3])
    XCTAssertEqual(states.map(\.leftLevel), [0, 0, 1, 1, 1, 3])
  }

  func testFiveFramesToGoDown() {
    var policy = AlertPolicy()
    let states = feed(&policy, levels: [3, 3, 3, 0, 0, 0, 0, 0, 0])
    XCTAssertEqual(states.map(\.leftLevel), [0, 0, 3, 3, 3, 3, 3, 0, 0])
  }

  func testBriefDropDoesNotLowerOutput() {
    var policy = AlertPolicy()
    let states = feed(&policy, levels: [2, 2, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2])
    XCTAssertTrue(states.dropFirst(2).allSatisfy { $0.leftLevel == 2 })
  }

  func testSidesDriveChannels() {
    var policy = AlertPolicy()
    var state = AlertState()
    for i in 0..<3 {
      state = policy.update(
        risk: frame([(1, 2, .left), (2, 1, .right)]), tracks: [track(1), track(2)], time: Double(i) / 15)
    }
    XCTAssertEqual(state.leftLevel, 2)
    XCTAssertEqual(state.rightLevel, 1)

    // AHEAD drives both; the max wins per side.
    var policy2 = AlertPolicy()
    for i in 0..<3 {
      state = policy2.update(
        risk: frame([(1, 3, .ahead), (2, 1, .right)]), tracks: [track(1), track(2)], time: Double(i) / 15)
    }
    XCTAssertEqual(state.leftLevel, 3)
    XCTAssertEqual(state.rightLevel, 3)
  }

  func testVanishedTrackStepsDownAfterFiveFrames() {
    var policy = AlertPolicy()
    _ = feed(&policy, levels: [3, 3, 3])
    var levels: [Int] = []
    for i in 0..<6 {
      levels.append(policy.update(risk: RiskFrame(), tracks: [], time: 1 + Double(i) / 15).leftLevel)
    }
    XCTAssertEqual(levels, [3, 3, 3, 3, 0, 0])
  }

  func testSpeaksOnceWhenReachingLevelTwo() {
    var policy = AlertPolicy()
    let states = feed(&policy, levels: [1, 1, 1, 2, 2, 2, 2, 2, 2], side: .left, cls: .bicycle)
    let cues = states.flatMap(\.cues)
    XCTAssertEqual(cues.map(\.text), ["bike, left"])
    XCTAssertEqual(states[5].cues.count, 1)  // spoken on the frame the smoothed level reaches 2
  }

  func testSpokenWords() {
    for (cls, side, expected) in [
      (ObjectClass.motorcycle, Side.right, "bike, right"), (.car, .ahead, "car, ahead"), (.bus, .left, "car, left"),
      (.truck, .ahead, "car, ahead"), (.person, .ahead, "person, ahead"),
    ] {
      var policy = AlertPolicy()
      XCTAssertEqual(feed(&policy, levels: [2, 2, 2], side: side, cls: cls).flatMap(\.cues).map(\.text), [expected])
    }
  }

  func testNoRepeatForSameTrackWithinFourSeconds() {
    var policy = AlertPolicy()
    // Level 2 for 1 s, then 3 for 1 s (escalation inside 4 s): only the first is spoken.
    let levels = Array(repeating: 2, count: 15) + Array(repeating: 3, count: 15)
    XCTAssertEqual(feed(&policy, levels: levels).flatMap(\.cues).count, 1)
    // Drops away, then comes back to level 2 five seconds later: spoken again.
    _ = feed(&policy, levels: Array(repeating: 0, count: 10), startTime: 2)
    let again = feed(&policy, levels: [2, 2, 2, 2], startTime: 6)
    XCTAssertEqual(again.flatMap(\.cues).count, 1)
  }

  func testSteadyHazardIsNotRepeated() {
    var policy = AlertPolicy()
    let cues = feed(&policy, levels: Array(repeating: 2, count: 15 * 10)).flatMap(\.cues)
    XCTAssertEqual(cues.count, 1)
  }

  func testNoWordTellsTheWearerWhatToDo() {
    let banned = ["safe", "clear", "go", "move", "cross", "stop", "turn"]
    for cls in ObjectClass.allCases {
      for side in [Side.left, .ahead, .right] {
        var policy = AlertPolicy()
        let text = feed(&policy, levels: [3, 3, 3], side: side, cls: cls).flatMap(\.cues).first!.text
        for word in banned { XCTAssertFalse(text.lowercased().contains(word), text) }
      }
    }
  }

  // The hackathon demo end to end (no camera): one person passes, one walks straight at the wearer.
  func testDemoScenarioSpeaksOnlyForThePersonOnCourse() {
    var tracker = Tracker(), estimator = RiskEstimator(), policy = AlertPolicy()
    var cues: [(time: Double, text: String)] = []
    var maxDuringPass = 0, maxDuringApproach = 0
    for i in 0..<Int(19.8 * 15) {
      let t = Double(i) / 15
      let tracks = tracker.update(Scenario.demo.detections(at: t), at: t)
      let risk = estimator.update(tracks: tracks, time: t, frameShift: 0)
      let state = policy.update(risk: risk, tracks: tracks, time: t)
      // The second person is 5 cm to the camera-right, so in the last moments the cue is right-only.
      XCTAssertLessThanOrEqual(state.leftLevel, state.rightLevel)
      for cue in state.cues { cues.append((t, cue.text)) }
      if t < 10 { maxDuringPass = max(maxDuringPass, state.rightLevel) } else { maxDuringApproach = max(maxDuringApproach, state.leftLevel) }
    }
    XCTAssertEqual(maxDuringPass, 0)
    XCTAssertEqual(maxDuringApproach, 3)
    // Nothing is spoken for the passer (before t = 10). The person on course is announced first as
    // "ahead"; a second cue for the same person ("right", as they close in) is allowed.
    XCTAssertEqual(cues.first?.text, "person, ahead")
    XCTAssertTrue(cues.allSatisfy { $0.time > 10 })
    XCTAssertTrue(cues.allSatisfy { $0.text.hasPrefix("person") })
    // Spoken when about 3.5 s remain (true contact is at 10.5 + 12/1.4 ≈ 19.07 s).
    XCTAssertEqual(19.07 - cues[0].time, 3.5, accuracy: 0.5)
  }
}

final class SpeechQueueTests: XCTestCase {
  private func cue(_ text: String, _ priority: Int) -> SpeechCue { SpeechCue(text: text, priority: priority, trackID: nil) }

  func testSpeaksImmediatelyWhenIdle() {
    var q = SpeechQueue()
    XCTAssertEqual(q.submit(cue("car, left", 2)), .speak(cue("car, left", 2), interrupt: false))
  }

  func testHigherPriorityInterrupts() {
    var q = SpeechQueue()
    _ = q.submit(cue("Watching", 0))
    XCTAssertEqual(q.submit(cue("bike, left", 3)), .speak(cue("bike, left", 3), interrupt: true))
    XCTAssertNil(q.finished())
  }

  func testNeverMoreThanOneWaitingAndNewerReplacesOlder() {
    var q = SpeechQueue()
    _ = q.submit(cue("car, ahead", 3))
    XCTAssertEqual(q.submit(cue("person, left", 2)), .wait)
    XCTAssertEqual(q.submit(cue("bike, right", 2)), .wait)
    XCTAssertEqual(q.finished(), cue("bike, right", 2))  // the older waiting cue was replaced
    XCTAssertNil(q.finished())
  }

  func testLowerPriorityDoesNotReplaceWaitingHazard() {
    var q = SpeechQueue()
    _ = q.submit(cue("car, ahead", 3))
    _ = q.submit(cue("person, left", 2))
    XCTAssertEqual(q.submit(cue("Watching resumed", 0)), .drop)
    XCTAssertEqual(q.finished(), cue("person, left", 2))
  }
}

final class PriorityTests: XCTestCase {
  private func track(_ id: Int, _ cls: ObjectClass = .person) -> Track {
    Track(id: id, objectClass: cls, confidence: 0.9, observations: [], left: -0.1, right: 0.1, top: 0.4, bottom: 0.8,
          lastSeen: 0, isCoasting: false, hits: 10)
  }

  // MARK: - Priority (rank by tau)

  private func ranked(_ items: [(id: Int, level: Int, tau: Double, center: Double)], frames: Int = 3) -> AlertState {
    var policy = AlertPolicy()
    let risk = RiskFrame(assessments: items.map {
      RiskAssessment(trackID: $0.id, state: .onCourse, tau: $0.tau, level: $0.level, side: .ahead,
                     predictedLeft: $0.center - 0.1, predictedRight: $0.center + 0.1)
    })
    var tracks: [Track] = []
    for item in items { tracks.append(track(item.id, .person)) }
    var state = AlertState()
    for i in 0..<frames { state = policy.update(risk: risk, tracks: tracks, time: Double(i) / 15) }
    return state
  }

  // Both level 2: the one arriving sooner (tau 1.6 s) wins over the older track (tau 2.4 s).
  func testLowestTauWins() {
    let state = ranked([(1, 2, 2.4, 0), (2, 2, 1.6, 0)])
    XCTAssertEqual(state.topTrackID, 2)
    XCTAssertEqual(state.cues.map(\.trackID), [2, 1])
  }

  // Same tau: the one nearest the centre (most directly at the wearer) wins.
  func testTauTieGoesToNearestCentre() {
    let state = ranked([(1, 2, 2.0, -0.12), (2, 2, 2.0, 0.03)])
    XCTAssertEqual(state.topTrackID, 2)
  }

  // Objects at level 0 are never the top object.
  func testLevelZeroIsNeverTop() {
    let state = ranked([(1, 0, 0.5, 0), (2, 1, 3.5, 0)])
    XCTAssertEqual(state.topTrackID, 2)
    XCTAssertNil(ranked([(1, 0, 0.5, 0)]).topTrackID)
  }
}
