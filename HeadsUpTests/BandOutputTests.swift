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
    // Never a silence longer than one command's on-time, so a steady level feels continuous.
    XCTAssertLessThan(gaps.max() ?? 1, BandConstants.buzzOnTime)
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

  func testSimulatedMotorsStopWhenTheOnTimeRunsOut() {
    let band = SimulatedBand()
    band.write([3, 2])
    let t = CACurrentMediaTime()
    XCTAssertEqual(band.motors(at: t + 0.3), [3, 2])
    XCTAssertEqual(band.motors(at: t + 0.5), [0, 0])
  }

  // The firmware takes one command per motor: [side, strength 0–255, on-time in 100 ms units].
  func testLevelsBecomeOneFirmwareCommandPerMotor() {
    XCTAssertEqual(BandConstants.commands(forLevels: [2, 0]), [[0, 160, 4], [1, 0, 4]])
    XCTAssertEqual(BandConstants.commands(forLevels: [0, 3]), [[0, 0, 4], [1, 255, 4]])
    // Strength rises with the level; level 0 is strength 0, which stops the motor.
    XCTAssertEqual(BandConstants.strengthForLevel.first, 0)
    XCTAssertEqual(BandConstants.strengthForLevel, BandConstants.strengthForLevel.sorted())
    XCTAssertEqual(BandConstants.strengthForLevel.count, 4)
    // A level above 3 is treated as 3; a malformed packet sends nothing.
    XCTAssertEqual(BandConstants.command(motor: 1, level: 9), [1, 255, 4])
    XCTAssertTrue(BandConstants.commands(forLevels: [1]).isEmpty)
    // The on-time must outlast the heartbeat, or a steady level would stutter.
    XCTAssertGreaterThan(BandConstants.buzzOnTime, BandConstants.heartbeatInterval)
  }

  // Both the real band and the on-screen one receive every packet.
  func testFanoutWritesToEveryTransport() {
    let a = SimulatedBand(), b = SimulatedBand()
    a.keepsLog = true
    b.keepsLog = true
    BandFanout([a, b]).write([1, 2])
    XCTAssertEqual(a.log.last?.packet, [1, 2])
    XCTAssertEqual(b.log.last?.packet, [1, 2])
  }
}
