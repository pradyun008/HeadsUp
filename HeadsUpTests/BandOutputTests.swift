import QuartzCore
import XCTest
@testable import HeadsUp

// 8. Band heartbeat sends every 200 ms, and the wrist swap flips the channels.
final class BandOutputTests: XCTestCase {
  private func wait(_ seconds: Double) {
    let done = expectation(description: "wait")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
    wait(for: [done], timeout: seconds + 2)
  }

  func testHeartbeatEvery200msEvenWhenNothingChanges() {
    let band = SimulatedBand()
    band.keepsLog = true
    let output = BandOutput(transport: band)
    output.start()
    wait(2.1)
    output.stop()

    // The last entry is the stop packet; the rest are heartbeats.
    let beats = band.log.dropLast()
    XCTAssertGreaterThanOrEqual(beats.count, 10)
    XCTAssertLessThanOrEqual(beats.count, 12)
    let gaps = zip(beats.dropFirst(), beats).map { $0.time - $1.time }
    for gap in gaps { XCTAssertEqual(gap, 0.2, accuracy: 0.06) }
    XCTAssertEqual(gaps.reduce(0, +) / Double(gaps.count), 0.2, accuracy: 0.01)
    XCTAssertTrue(beats.allSatisfy { $0.packet == [0, 0] })  // sent although nothing changed
    // Never a silence long enough to trip the firmware's 600 ms timeout.
    XCTAssertLessThan(gaps.max() ?? 1, BandConstants.firmwareTimeout)
  }

  func testLevelChangeIsWrittenAtOnceAndThenRepeated() {
    let band = SimulatedBand()
    band.keepsLog = true
    let output = BandOutput(transport: band)
    output.start()
    wait(0.1)
    let before = CACurrentMediaTime()
    output.setLevels(left: 2, right: 0)
    let first = band.log.last!
    XCTAssertEqual(first.packet, [2, 0])
    XCTAssertLessThan(first.time - before, 0.02)  // not delayed until the next heartbeat
    wait(0.5)
    XCTAssertGreaterThanOrEqual(band.log.filter { $0.packet == [2, 0] }.count, 3)
    output.stop()
    XCTAssertEqual(band.log.last?.packet, [0, 0])  // motors off on stop
  }

  func testWristSwapFlipsChannels() {
    XCTAssertEqual(BandOutput.packet(left: 3, right: 1, swap: false), [3, 1])
    XCTAssertEqual(BandOutput.packet(left: 3, right: 1, swap: true), [1, 3])

    let band = SimulatedBand()
    band.keepsLog = true
    let output = BandOutput(transport: band)
    output.setLevels(left: 3, right: 1)
    XCTAssertEqual(band.log.last?.packet, [3, 1])
    output.swapChannels = true
    XCTAssertEqual(band.log.last?.packet, [1, 3])  // re-sent at once with the bytes exchanged
    output.setLevels(left: 0, right: 2)
    XCTAssertEqual(band.log.last?.packet, [2, 0])
  }

  func testPacketIsTwoBytesClampedToZeroThroughThree() {
    XCTAssertEqual(BandOutput.packet(left: 7, right: -2, swap: false), [3, 0])
    XCTAssertEqual(BandOutput.packet(left: 0, right: 0, swap: true).count, 2)
  }

  func testSimulatedFirmwareTurnsMotorsOffAfter600msOfSilence() {
    let band = SimulatedBand()
    band.write([3, 2])
    let t = CACurrentMediaTime()
    XCTAssertEqual(band.motors(at: t + 0.5), [3, 2])
    XCTAssertEqual(band.motors(at: t + 0.7), [0, 0])
  }
}
