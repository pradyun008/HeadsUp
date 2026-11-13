import CoreHaptics
import Foundation

/// What the phone's single vibration motor plays for a pair of levels.
/// With one motor, side is a pattern: one pulse = left cue, two pulses = right cue,
/// a long buzz = ahead. The pattern repeats faster as the level rises.
/// Like the band, these are cues that report where a hazard is, never instructions.
struct HapticCue: Equatable, Sendable {
  enum Kind: String, Sendable { case singlePulse, doublePulse, longBuzz }

  var kind: Kind
  /// 1–3.
  var level: Int

  /// Seconds between repeats: shorter (faster) at higher levels.
  var period: Double { [1.0, 0.6, 0.35][min(3, max(1, level)) - 1] }

  /// Vibration bursts within one repeat, as (start, duration) in seconds.
  var bursts: [(start: Double, duration: Double)] {
    switch kind {
    case .singlePulse: return [(0, 0.07)]
    case .doublePulse: return [(0, 0.07), (0.14, 0.07)]
    case .longBuzz: return [(0, period * 0.7)]
    }
  }

  /// The cue for the two output levels, or nil when both are 0.
  /// Equal non-zero levels mean a hazard ahead. If both sides are active at different levels,
  /// the stronger side wins: one motor cannot play two patterns at once.
  static func make(left: Int, right: Int) -> HapticCue? {
    if left <= 0 && right <= 0 { return nil }
    if left == right { return HapticCue(kind: .longBuzz, level: left) }
    return left > right ? HapticCue(kind: .singlePulse, level: left) : HapticCue(kind: .doublePulse, level: right)
  }
}

/// Phone-vibration fallback for when there is no band. Uses Core Haptics.
final class PhoneHapticOutput: @unchecked Sendable {
  private let queue = DispatchQueue(label: "headsup.haptics", qos: .userInitiated)
  private var engine: CHHapticEngine?
  private var timer: DispatchSourceTimer?
  private var current: HapticCue?

  /// False on devices without a haptic motor (and in the Simulator).
  static var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

  /// Safe from any thread.
  func setLevels(left: Int, right: Int) {
    let cue = HapticCue.make(left: left, right: right)
    queue.async { [self] in
      guard cue != current else { return }
      current = cue
      timer?.cancel()
      timer = nil
      guard let cue, Self.isSupported else { return }
      // Play at once, then repeat at the level's rate.
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: cue.period, leeway: .milliseconds(5))
      timer.setEventHandler { [weak self] in self?.play(cue) }
      self.timer = timer
      timer.resume()
    }
  }

  func stop() {
    queue.async { [self] in
      current = nil
      timer?.cancel()
      timer = nil
      engine?.stop()
      engine = nil
    }
  }

  private func play(_ cue: HapticCue) {
    do {
      if engine == nil {
        let engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        // The system can stop or reset the engine (audio interruption, app backgrounded):
        // drop it and make a new one on the next pulse.
        engine.stoppedHandler = { [weak self] _ in self?.queue.async { self?.engine = nil } }
        engine.resetHandler = { [weak self] in self?.queue.async { self?.engine = nil } }
        try engine.start()
        self.engine = engine
      }
      let intensity = Float([0.6, 0.8, 1.0][min(3, max(1, cue.level)) - 1])
      let events = cue.bursts.map { burst in
        CHHapticEvent(
          eventType: .hapticContinuous,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
          ],
          relativeTime: burst.start, duration: burst.duration)
      }
      let player = try engine?.makePlayer(with: CHHapticPattern(events: events, parameters: []))
      try player?.start(atTime: CHHapticTimeImmediate)
    } catch {
      engine = nil
    }
  }
}
