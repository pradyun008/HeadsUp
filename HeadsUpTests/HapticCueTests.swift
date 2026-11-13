import XCTest
@testable import HeadsUp

final class HapticCueTests: XCTestCase {
  func testNothingWhenBothLevelsAreZero() {
    XCTAssertNil(HapticCue.make(left: 0, right: 0))
  }

  func testOnePulseIsLeftTwoIsRightLongBuzzIsAhead() {
    XCTAssertEqual(HapticCue.make(left: 2, right: 0), HapticCue(kind: .singlePulse, level: 2))
    XCTAssertEqual(HapticCue.make(left: 0, right: 2), HapticCue(kind: .doublePulse, level: 2))
    XCTAssertEqual(HapticCue.make(left: 2, right: 2), HapticCue(kind: .longBuzz, level: 2))
    XCTAssertEqual(HapticCue(kind: .singlePulse, level: 1).bursts.count, 1)
    XCTAssertEqual(HapticCue(kind: .doublePulse, level: 1).bursts.count, 2)
    XCTAssertEqual(HapticCue(kind: .longBuzz, level: 1).bursts.count, 1)
    XCTAssertGreaterThan(HapticCue(kind: .longBuzz, level: 1).bursts[0].duration, 0.5)
  }

  func testStrongerSideWinsWhenBothAreActive() {
    XCTAssertEqual(HapticCue.make(left: 3, right: 1), HapticCue(kind: .singlePulse, level: 3))
    XCTAssertEqual(HapticCue.make(left: 1, right: 2), HapticCue(kind: .doublePulse, level: 2))
  }

  func testRepeatsFasterAsLevelRises() {
    for kind in [HapticCue.Kind.singlePulse, .doublePulse, .longBuzz] {
      let periods = (1...3).map { HapticCue(kind: kind, level: $0).period }
      XCTAssertEqual(periods, periods.sorted(by: >))
      XCTAssertGreaterThan(periods[0], periods[2])
      // Every burst finishes before the pattern repeats.
      for level in 1...3 {
        let cue = HapticCue(kind: kind, level: level)
        for burst in cue.bursts { XCTAssertLessThan(burst.start + burst.duration, cue.period) }
      }
    }
  }
}
