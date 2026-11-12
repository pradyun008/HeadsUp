import XCTest
@testable import HeadsUp

final class ScenarioTests: XCTestCase {
  func testApproachingPersonStaysCentredAndGrows() {
    let s = Scenario.walksToward
    let early = s.detections(at: 1).first!, late = s.detections(at: 7).first!
    XCTAssertEqual(early.centerX, 0, accuracy: 0.001)
    XCTAssertEqual(late.centerX, 0, accuracy: 0.001)
    XCTAssertGreaterThan(late.area, early.area * 4)
  }

  func testPassingPersonSlidesTowardRightEdge() {
    let s = Scenario.walksPast
    let early = s.detections(at: 1).first!, late = s.detections(at: 7).first!
    XCTAssertGreaterThan(late.centerX, early.centerX + 0.3)
    XCTAssertGreaterThan(late.left, 0.15)  // clear of the corridor
  }

  func testCrossingFarKeepsSize() {
    let s = Scenario.crossesFar
    let a = s.detections(at: 2).first!, b = s.detections(at: 6).first!
    XCTAssertEqual(a.height, b.height, accuracy: 0.001)
    XCTAssertGreaterThan(b.centerX, a.centerX)
  }

  func testNothingBeforeStartOrAfterEnd() {
    XCTAssertTrue(Scenario.walksToward.detections(at: 0.1).isEmpty)
    XCTAssertTrue(Scenario.walksToward.detections(at: 9.5).isEmpty)
  }
}
