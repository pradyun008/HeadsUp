import XCTest
@testable import HeadsUp

/// Hazard speech against navigation speech, scripted (no audio).
final class SpeechArbiterTests: XCTestCase {
  private let origin = GeoPoint(lat: 40.3500, lon: -74.6590)
  private func at(_ east: Double, _ north: Double) -> GeoPoint { Geo.point(from: origin, east: east, north: north) }
  private func hazard(_ text: String, _ level: Int) -> SpeechCue { SpeechCue(text: text, priority: level, trackID: 1) }
  private let status = SpeechCue(text: "Watching", priority: 0, trackID: nil)
  private let same: SpeechArbiter.Refresh = { $0 }

  /// An engine walking north toward a right turn 150 m ahead, and a way to move it.
  private func engineAtAdvanceNotice() -> (engine: NavigationEngine, advance: NavCue, walk: (inout NavigationEngine, Double) -> Void) {
    var engine = NavigationEngine()
    engine.start(
      NavRoute(
        path: RoutePath([at(0, 0), at(0, 150), at(120, 150)]),
        junctions: [.init(along: 150, street: "Witherspoon Street")],
        destinationName: "McDonald's"))
    var time = 0.0
    var advance: NavCue?
    func walk(_ engine: inout NavigationEngine, to north: Double) {
      var y = engine.along
      while y < north {
        y += 1.4
        time += 1
        for cue in engine.update(LocationFix(point: self.at(0, y), time: time)) where cue.kind == .advance { advance = cue }
      }
    }
    walk(&engine, to: 105)
    return (engine, advance!, { engine, north in walk(&engine, to: north) })
  }

  // 8. A hazard during a turn cue: the hazard speaks at once, then the cue returns with a fresh distance.
  func testHazardCutsOffNavCueWhichReturnsWithFreshDistance() {
    var (engine, advance, walk) = engineAtAdvanceNotice()
    var arbiter = SpeechArbiter()
    XCTAssertEqual(arbiter.submit(advance), .speak("In about 150 feet, turn right onto Witherspoon Street.", interrupt: false))

    // A person walks straight at the wearer mid-sentence.
    XCTAssertNil(arbiter.setHazardLevel(3, refresh: { engine.refreshed($0) }))
    XCTAssertEqual(arbiter.submit(hazard("person, ahead", 3)), .speak("person, ahead", interrupt: true))
    XCTAssertEqual(arbiter.waitingText, advance.text)

    // The wearer keeps walking while the hazard is spoken and is still close.
    walk(&engine, 126)
    XCTAssertNil(arbiter.finished(refresh: { engine.refreshed($0) }), "nothing new while the hazard level is high")

    // The hazard passes: the cue comes back, worded for where the wearer is now (about 25 m
    // before the turn), not with the stale "150 feet".
    XCTAssertEqual(
      arbiter.setHazardLevel(0, refresh: { engine.refreshed($0) }),
      "In about 80 feet, turn right onto Witherspoon Street.")
    XCTAssertNil(arbiter.waitingText)
  }

  // 9. The turn is passed while the hazard is spoken: the stale cue is dropped, not replayed.
  func testStaleNavCueIsDroppedAfterHazard() {
    var (engine, advance, walk) = engineAtAdvanceNotice()
    var arbiter = SpeechArbiter()
    _ = arbiter.submit(advance)
    _ = arbiter.setHazardLevel(3, refresh: same)
    _ = arbiter.submit(hazard("bike, left", 3))
    walk(&engine, 146)  // now inside "Turn right" distance
    _ = arbiter.finished(refresh: { engine.refreshed($0) })
    XCTAssertNil(arbiter.setHazardLevel(0, refresh: { engine.refreshed($0) }))
    XCTAssertNil(arbiter.waitingText)
    XCTAssertNil(arbiter.speakingText)
  }

  // 10. No navigation cue starts while the hazard level is high or urgent.
  func testNavCueWaitsWhileHazardLevelIsHigh() {
    var arbiter = SpeechArbiter()
    _ = arbiter.setHazardLevel(2, refresh: same)
    let turn = NavCue(kind: .imminent, text: "Turn left.", maneuver: 0)
    XCTAssertEqual(arbiter.submit(turn), .wait)
    XCTAssertNil(arbiter.speakingText)
    // Level 1 is low enough.
    XCTAssertEqual(arbiter.setHazardLevel(1, refresh: same), "Turn left.")
  }

  func testOrderOfImportance() {
    let turn = NavCue(kind: .imminent, text: "Turn left.", maneuver: 0)
    let advance = NavCue(kind: .advance, text: "In about 150 feet, turn left.", maneuver: 0)

    // "Turn left" replaces the advance notice being spoken; the notice is not replayed.
    var a = SpeechArbiter()
    _ = a.submit(advance)
    XCTAssertEqual(a.submit(turn), .speak("Turn left.", interrupt: true))
    XCTAssertNil(a.finished(refresh: same))

    // A navigation cue does not interrupt a hazard cue; it waits.
    var b = SpeechArbiter()
    _ = b.submit(hazard("car, left", 2))
    XCTAssertEqual(b.submit(turn), .wait)
    XCTAssertEqual(b.finished(refresh: same), "Turn left.")

    // A level-2 hazard interrupts even "Turn left".
    var c = SpeechArbiter()
    _ = c.submit(turn)
    XCTAssertEqual(c.submit(hazard("car, left", 2)), .speak("car, left", interrupt: true))

    // Status waits for navigation, and navigation interrupts status.
    var d = SpeechArbiter()
    _ = d.submit(turn)
    XCTAssertEqual(d.submit(status), .wait)
    XCTAssertEqual(d.finished(refresh: same), "Watching")
    XCTAssertEqual(d.submit(advance), .speak(advance.text, interrupt: true))
  }

  func testOnlyOneNavCueWaitsAndNewerReplacesOlder() {
    var arbiter = SpeechArbiter()
    _ = arbiter.submit(hazard("car, ahead", 3))
    XCTAssertEqual(arbiter.submit(NavCue(kind: .advance, text: "old", maneuver: 0)), .wait)
    XCTAssertEqual(arbiter.submit(NavCue(kind: .advance, text: "new", maneuver: 1)), .wait)
    XCTAssertEqual(arbiter.finished(refresh: same), "new")
    XCTAssertNil(arbiter.finished(refresh: same))
  }

  func testReassuranceIsSkippedWhileAnyHazardIsActive() {
    var arbiter = SpeechArbiter()
    _ = arbiter.setHazardLevel(1, refresh: same)
    XCTAssertEqual(arbiter.submit(NavCue(kind: .reassurance, text: "Continue straight, 600 feet.")), .drop)
    _ = arbiter.setHazardLevel(0, refresh: same)
    XCTAssertEqual(
      arbiter.submit(NavCue(kind: .reassurance, text: "Continue straight, 600 feet.")),
      .speak("Continue straight, 600 feet.", interrupt: false))
  }

  // Hazard cues alone behave exactly as the old speech queue did.
  func testHazardOnlyBehaviourIsUnchanged() {
    var arbiter = SpeechArbiter()
    XCTAssertEqual(arbiter.submit(status), .speak("Watching", interrupt: false))
    XCTAssertEqual(arbiter.submit(hazard("bike, left", 3)), .speak("bike, left", interrupt: true))
    XCTAssertEqual(arbiter.submit(hazard("person, left", 2)), .wait)
    XCTAssertEqual(arbiter.submit(hazard("car, right", 2)), .wait)
    XCTAssertEqual(arbiter.submit(status), .drop)
    XCTAssertEqual(arbiter.finished(refresh: same), "car, right")
    XCTAssertNil(arbiter.finished(refresh: same))
  }
}
