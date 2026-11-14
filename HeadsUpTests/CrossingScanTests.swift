import XCTest
@testable import HeadsUp

final class CrossingScanTests: XCTestCase {
  private func track(_ id: Int, _ cls: ObjectClass, coasting: Bool = false) -> Track {
    Track(id: id, objectClass: cls, confidence: 0.9, observations: [], left: -0.2, right: 0.2, top: 0.4, bottom: 0.8,
          lastSeen: 0, isCoasting: coasting, hits: 5)
  }

  private func log(_ frames: [(ScanPhase, [Track])]) -> CrossingScanLog {
    var log = CrossingScanLog()
    for (phase, tracks) in frames { log.observe(tracks, phase: phase) }
    return log
  }

  func testNothingSeen() {
    XCTAssertEqual(CrossingScanLog().report, "nothing seen")
    XCTAssertEqual(log(Array(repeating: (.left, []), count: 30)).report, "nothing seen")
  }

  func testCarSeenWhileLookingLeft() {
    let frames = Array(repeating: (ScanPhase.left, [track(1, .car)]), count: 10) + Array(repeating: (ScanPhase.right, []), count: 10)
    XCTAssertEqual(log(frames).report, "car, left")
  }

  func testReportsEachSideLeftFirstCarsBeforeBikes() {
    var frames: [(ScanPhase, [Track])] = Array(repeating: (.left, [track(1, .bicycle), track(2, .truck)]), count: 5)
    frames += Array(repeating: (.right, [track(3, .bus)]), count: 5)
    XCTAssertEqual(log(frames).report, "car, left. bike, left. car, right")
  }

  func testPeopleAreNotReported() {
    XCTAssertEqual(log(Array(repeating: (.left, [track(1, .person)]), count: 20)).report, "nothing seen")
  }

  func testOneOrTwoFramesAreNotEnough() {
    XCTAssertEqual(log(Array(repeating: (.right, [track(1, .car)]), count: 2)).report, "nothing seen")
    XCTAssertEqual(log(Array(repeating: (.right, [track(1, .car)]), count: 3)).report, "car, right")
  }

  func testChangingTrackIDsStillCount() {
    // A head turn can give the same car a new ID every frame.
    let frames = (1...6).map { (ScanPhase.left, [track($0, .car)]) }
    XCTAssertEqual(log(frames).report, "car, left")
  }

  func testCoastingTracksDoNotCount() {
    XCTAssertEqual(log(Array(repeating: (.left, [track(1, .car, coasting: true)]), count: 20)).report, "nothing seen")
  }

  func testReportNeverGivesAVerdict() {
    let banned = ["safe", "clear", "go", "cross", "walk", "stop", "wait", "ok"]
    var frames: [(ScanPhase, [Track])] = Array(repeating: (.left, [track(1, .car), track(2, .motorcycle)]), count: 5)
    frames += Array(repeating: (.right, [track(3, .car)]), count: 5)
    for report in [CrossingScanLog().report, log(frames).report] {
      let words = report.lowercased().components(separatedBy: CharacterSet.letters.inverted)
      for word in banned { XCTAssertFalse(words.contains(word), report) }
    }
  }

  func testTriggerPhrase() {
    for said in ["HeadsUp, crossing", "Heads up, crossing.", "heads up crossing", "hey heads-up... crossing now", "Head up crossing"] {
      XCTAssertTrue(CrossingScanPhrase.matches(said), said)
    }
    for said in ["crossing the street", "heads up", "crossing, heads up", "what's up", ""] {
      XCTAssertFalse(CrossingScanPhrase.matches(said), said)
    }
  }

  func testStopAfterWalkingFiresOnceAfterThreeSeconds() {
    var logic = StopWalkingLogic()
    XCTAssertFalse(logic.update(time: 0, walking: true))
    XCTAssertFalse(logic.update(time: 5, walking: false))
    XCTAssertFalse(logic.update(time: 7.9, walking: false))
    XCTAssertTrue(logic.update(time: 8.0, walking: false))
    // Standing on: no second scan until walking again.
    XCTAssertFalse(logic.update(time: 20, walking: false))
    XCTAssertFalse(logic.update(time: 21, walking: true))
    XCTAssertFalse(logic.update(time: 22, walking: false))
    XCTAssertTrue(logic.update(time: 25, walking: false))
  }

  func testNoFireWithoutWalkingFirstOrAfterABriefPause() {
    var logic = StopWalkingLogic()
    XCTAssertFalse(logic.update(time: 0, walking: false))
    XCTAssertFalse(logic.update(time: 10, walking: false))
    // Walk, pause 2 s, walk again: nothing.
    XCTAssertFalse(logic.update(time: 11, walking: true))
    XCTAssertFalse(logic.update(time: 12, walking: false))
    XCTAssertFalse(logic.update(time: 14, walking: false))
    XCTAssertFalse(logic.update(time: 14.5, walking: true))
    XCTAssertFalse(logic.update(time: 15, walking: false))
    XCTAssertFalse(logic.update(time: 17.9, walking: false))
  }
}
