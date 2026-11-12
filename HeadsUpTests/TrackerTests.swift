import XCTest
@testable import HeadsUp

final class TrackerTests: XCTestCase {
  private func box(_ cls: ObjectClass = .person, cx: Double, w: Double = 0.2, top: Double = 0.4, bottom: Double = 0.7) -> Detection {
    Detection(objectClass: cls, confidence: 0.9, left: cx - w / 2, right: cx + w / 2, top: top, bottom: bottom)
  }

  func testMovingObjectKeepsOneID() {
    var tracker = Tracker()
    var ids = Set<Int>()
    for i in 0..<30 {
      let tracks = tracker.update([box(cx: -0.5 + Double(i) * 0.02)], at: Double(i) / 15)
      XCTAssertEqual(tracks.count, 1)
      ids.insert(tracks[0].id)
    }
    XCTAssertEqual(ids.count, 1)
  }

  func testTwoObjectsKeepSeparateIDs() {
    var tracker = Tracker()
    var first: [Int] = []
    for i in 0..<20 {
      let t = Double(i) / 15
      // Listed in changing order to check that matching is by position, not by index.
      let dets = [box(cx: -0.6 + Double(i) * 0.01), box(cx: 0.6 - Double(i) * 0.01)]
      let tracks = tracker.update(i % 2 == 0 ? dets : dets.reversed(), at: t)
      XCTAssertEqual(tracks.count, 2)
      let leftID = tracks.min { $0.centerX < $1.centerX }!.id
      first.append(leftID)
    }
    XCTAssertEqual(Set(first).count, 1)
  }

  func testCoastsThroughShortGapAndKeepsID() {
    var tracker = Tracker()
    var t = 0.0
    for i in 0..<10 {
      t = Double(i) / 15
      tracker.update([box(cx: Double(i) * 0.02)], at: t)
    }
    let id = tracker.tracks[0].id
    let xBefore = tracker.tracks[0].centerX
    // 0.5 s with no detections (occlusion or head turn).
    for _ in 0..<7 {
      t += 1.0 / 15
      let tracks = tracker.update([], at: t)
      XCTAssertEqual(tracks.count, 1)
      XCTAssertTrue(tracks[0].isCoasting)
    }
    // Coasting keeps moving at the last velocity (0.3 units/s).
    XCTAssertEqual(tracker.tracks[0].centerX, xBefore + 0.3 * 7 / 15, accuracy: 0.03)
    // It reappears where it would have been: same ID, no longer coasting.
    t += 1.0 / 15
    let tracks = tracker.update([box(cx: xBefore + 0.3 * 8 / 15)], at: t)
    XCTAssertEqual(tracks.count, 1)
    XCTAssertEqual(tracks[0].id, id)
    XCTAssertFalse(tracks[0].isCoasting)
  }

  func testDroppedAfterOneSecondUnseen() {
    var tracker = Tracker()
    tracker.update([box(cx: 0)], at: 0)
    XCTAssertEqual(tracker.update([], at: 0.9).count, 1)
    XCTAssertEqual(tracker.update([], at: 1.1).count, 0)
    // A new object afterwards gets a new ID.
    XCTAssertEqual(tracker.update([box(cx: 0)], at: 1.2)[0].id, 2)
  }

  func testDifferentClassDoesNotMatch() {
    var tracker = Tracker()
    tracker.update([box(.person, cx: 0)], at: 0)
    let tracks = tracker.update([box(.car, cx: 0)], at: 1.0 / 15)
    XCTAssertEqual(Set(tracks.map(\.id)).count, 2)
  }

  func testCarTruckFlickerStaysOneTrack() {
    var tracker = Tracker()
    for i in 0..<10 {
      let tracks = tracker.update([box(i % 2 == 0 ? .car : .truck, cx: 0, w: 0.6)], at: Double(i) / 15)
      XCTAssertEqual(tracks.count, 1)
      XCTAssertEqual(tracks[0].id, 1)
    }
  }

  func testHistoryKeepsAboutOneSecond() {
    var tracker = Tracker()
    for i in 0..<60 { tracker.update([box(cx: 0)], at: Double(i) / 15) }
    let track = tracker.tracks[0]
    XCTAssertEqual(track.historySpan, 1.0, accuracy: 0.07)
    XCTAssertEqual(track.observations.count, 16, accuracy: 1)
    XCTAssertEqual(track.hits, 60)
  }

  func testDemoScenarioProducesExactlyTwoTracks() {
    var tracker = Tracker()
    var ids = Set<Int>()
    for i in 0..<300 {
      let t = Double(i) / 15
      for track in tracker.update(Scenario.demo.detections(at: t), at: t) { ids.insert(track.id) }
    }
    XCTAssertEqual(ids, [1, 2])
  }
}
