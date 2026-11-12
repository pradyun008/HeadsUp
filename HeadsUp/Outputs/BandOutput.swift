import Foundation
import QuartzCore

/// Where band packets go. The real one will be Core Bluetooth (write-without-response);
/// this build only has the simulated one.
protocol BandTransport: AnyObject, Sendable {
  /// Sends one 2-byte packet: `[first motor level, second motor level]`, each 0–3.
  func write(_ packet: [UInt8])
}

/// Drives the two-motor wristband: sends `[leftLevel, rightLevel]` every 200 ms as a heartbeat
/// (the firmware switches the motors off if it hears nothing for 600 ms), and at once when a
/// level changes so a new hazard is not delayed by up to a heartbeat.
///
/// The two motors are two learned cues ("left cue", "right cue"), not literal directions:
/// inner and outer wrist do not stay left and right as the arm rotates. `swapChannels` is the
/// "which wrist" setting and exchanges the two bytes.
final class BandOutput: @unchecked Sendable {
  private let transport: BandTransport
  private let interval: TimeInterval
  private let queue = DispatchQueue(label: "headsup.band", qos: .userInitiated)
  private let lock = NSLock()
  private var left = 0
  private var right = 0
  private var swap = false
  private var timer: DispatchSourceTimer?

  init(transport: BandTransport, interval: TimeInterval = BandConstants.heartbeatInterval) {
    self.transport = transport
    self.interval = interval
  }

  var swapChannels: Bool {
    get { lock.withLock { swap } }
    set {
      lock.withLock { swap = newValue }
      sendNow()
    }
  }

  /// The bytes for the given levels. Levels are clamped to 0–3.
  static func packet(left: Int, right: Int, swap: Bool) -> [UInt8] {
    let l = UInt8(min(3, max(0, left))), r = UInt8(min(3, max(0, right)))
    return swap ? [r, l] : [l, r]
  }

  /// Starts the heartbeat. Sends immediately, then every `interval`.
  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
    timer.setEventHandler { [weak self] in self?.sendNow() }
    self.timer = timer
    timer.resume()
  }

  /// Stops the heartbeat and switches both motors off.
  func stop() {
    lock.lock()
    timer?.cancel()
    timer = nil
    left = 0
    right = 0
    lock.unlock()
    sendNow()
  }

  /// Safe to call from any thread. A change is written at once; the heartbeat repeats it.
  func setLevels(left: Int, right: Int) {
    lock.lock()
    let changed = left != self.left || right != self.right
    self.left = left
    self.right = right
    lock.unlock()
    if changed { sendNow() }
  }

  private func sendNow() {
    let packet = lock.withLock { Self.packet(left: left, right: right, swap: swap) }
    transport.write(packet)
  }
}

/// Stands in for the wristband: remembers what was written and applies the firmware's
/// 600 ms silence timeout, so the screen can show what the motors would be doing.
final class SimulatedBand: BandTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var lastPacket: [UInt8] = [0, 0]
  private var lastWrite: CFTimeInterval?
  private var times: [CFTimeInterval] = []
  private(set) var log: [(time: CFTimeInterval, packet: [UInt8])] = []
  /// Keep every write (for tests). Off by default so a long session does not grow memory.
  var keepsLog = false
  var onWrite: (@Sendable (_ packet: [UInt8], _ time: CFTimeInterval) -> Void)?

  func write(_ packet: [UInt8]) {
    let now = CACurrentMediaTime()
    lock.lock()
    lastPacket = packet
    lastWrite = now
    times.append(now)
    times.removeAll { now - $0 > 2 }
    if keepsLog { log.append((now, packet)) }
    lock.unlock()
    onWrite?(packet, now)
  }

  /// What the two motors are doing at `now`: the last packet, or off after 600 ms of silence.
  func motors(at now: CFTimeInterval = CACurrentMediaTime()) -> [UInt8] {
    lock.withLock {
      guard let lastWrite, now - lastWrite <= BandConstants.firmwareTimeout else { return [0, 0] }
      return lastPacket
    }
  }

  /// Writes per second over the last two seconds.
  var writeRate: Double {
    lock.withLock {
      guard let first = times.first, let last = times.last, times.count >= 2, last > first else { return 0 }
      return Double(times.count - 1) / (last - first)
    }
  }
}
