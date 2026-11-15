import CoreMotion
import Foundation

/// What the wearer is doing, as far as "Is it moving?" is concerned.
enum WearerMotion: Equatable, Sendable {
  /// Not walking (or not known yet): the wearer adds nothing to the closing speed,
  /// so anything growing on course is moving toward them. No speed math needed.
  case stationary
  /// Walking at `speed` metres per second. `fromPace` is false while the default speed is used.
  case walking(speed: Double, fromPace: Bool)
}

/// The rules that turn activity labels and pace readings into a `WearerMotion`.
/// Plain logic with no sensors, so it can be unit-tested.
///
/// - Activity label first: stationary (or unknown) → `.stationary`, skip the speed math.
/// - Walking → speed = 1 ÷ pace (pace is seconds per metre), holding the last reading.
/// - Walking but no pace reading yet in this walk → `MeasuredConstants.defaultWalkingSpeed`.
struct WalkingSpeedEstimator: Sendable {
  enum Activity: Equatable, Sendable { case unknown, stationary, walking }

  private(set) var activity: Activity = .unknown
  private var paceSpeed: Double?

  mutating func activityChanged(_ newActivity: Activity) {
    // A new walk starts on the cautious default until its first fresh pace reading.
    if newActivity != .walking { paceSpeed = nil }
    activity = newActivity
  }

  /// Pace in seconds per metre, as CMPedometer reports it. Ignored unless walking.
  mutating func paceReading(secondsPerMetre: Double?) {
    guard activity == .walking, let pace = secondsPerMetre, pace > 0 else { return }
    paceSpeed = 1 / pace
  }

  var current: WearerMotion {
    switch activity {
    case .unknown, .stationary:
      return .stationary
    case .walking:
      if let paceSpeed { return .walking(speed: paceSpeed, fromPace: true) }
      return .walking(speed: MeasuredConstants.defaultWalkingSpeed, fromPace: false)
    }
  }
}

/// Walking yes/no from the phone's own accelerometer, so it reacts in 1–2 s instead of the
/// ~10 s Apple's activity label takes (measured 2026-11-15, Run A). Both directions matter:
/// a slow "walking" → "stationary" switch is the dangerous one, because it subtracts walking
/// speed while the wearer stands still and can hide a real mover.
///
/// How: each step shakes the phone (about 2 bumps a second). Standing still, the shake is near
/// zero. `wobble` = root-mean-square of the acceleration (gravity removed, in g) over the last
/// `MeasuredConstants.stepWindow` seconds. Above `MeasuredConstants.stepWobbleStart` = walking;
/// back to stationary only below `MeasuredConstants.stepWobbleStop`.
/// Plain logic with no sensors, so it can be unit-tested.
struct StepDetector: Sendable {
  private var samples: [(time: Double, squared: Double)] = []
  private var sum = 0.0
  /// Root-mean-square acceleration over the window, in g. Shown on the Debug tab.
  private(set) var wobble = 0.0
  private(set) var isWalking = false

  /// Add one sample: the size of the acceleration with gravity removed, in g.
  /// Returns true when `isWalking` changed.
  @discardableResult
  mutating func add(acceleration: Double, at time: Double) -> Bool {
    let squared = acceleration * acceleration
    samples.append((time, squared))
    sum += squared
    while let first = samples.first, time - first.time > MeasuredConstants.stepWindow {
      sum -= first.squared
      samples.removeFirst()
    }
    wobble = (max(0, sum) / Double(samples.count)).squareRoot()
    // Until the window has filled once (just started), stay stationary: subtract nothing.
    let full = time - (samples.first?.time ?? time) >= 0.9 * MeasuredConstants.stepWindow
    // Two lines with a gap: start walking above the higher one, stop only below the lower one.
    let line = isWalking ? MeasuredConstants.stepWobbleStop : MeasuredConstants.stepWobbleStart
    let walking = full && wobble > line
    defer { isWalking = walking }
    return walking != isWalking
  }
}

/// Feeds the step detector (walking yes/no) and pedometer pace (walking speed) into a
/// `WalkingSpeedEstimator`. Needs the Motion & Fitness permission (NSMotionUsageDescription).
/// If the phone has no accelerometer data, it falls back to Apple's activity labels (slow).
/// If neither is available the wearer stays `.stationary` (subtract nothing: no misses).
final class MotionSource: @unchecked Sendable {
  private let motionManager = CMMotionManager()
  private let activityManager = CMMotionActivityManager()
  private let pedometer = CMPedometer()
  private let queue = OperationQueue()
  private let lock = NSLock()
  private var estimator = WalkingSpeedEstimator()
  private var steps = StepDetector()

  /// Safe to read from any thread (the pipeline reads it once per frame).
  var current: WearerMotion { lock.withLock { estimator.current } }
  /// The step detector's current shake, in g, for the Debug tab.
  var wobble: Double { lock.withLock { steps.wobble } }

  func start() {
    lock.withLock {
      estimator = WalkingSpeedEstimator()
      steps = StepDetector()
    }
    queue.maxConcurrentOperationCount = 1
    if motionManager.isDeviceMotionAvailable {
      // 50 samples a second: plenty for ~2 steps a second.
      motionManager.deviceMotionUpdateInterval = 1.0 / 50
      motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
        guard let self, let motion else { return }
        let a = motion.userAcceleration
        let size = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        self.lock.withLock {
          if self.steps.add(acceleration: size, at: motion.timestamp) {
            self.estimator.activityChanged(self.steps.isWalking ? .walking : .stationary)
          }
        }
      }
    } else if CMMotionActivityManager.isActivityAvailable() {
      activityManager.startActivityUpdates(to: queue) { [weak self] activity in
        // Low-confidence labels are ignored; the previous label stays.
        guard let self, let activity, activity.confidence != .low else { return }
        let mapped: WalkingSpeedEstimator.Activity
        if activity.walking || activity.running {
          mapped = .walking
        } else if activity.stationary {
          mapped = .stationary
        } else {
          mapped = .unknown  // cycling, driving, unknown: pedometer pace means nothing there
        }
        self.lock.withLock { self.estimator.activityChanged(mapped) }
      }
    }
    if CMPedometer.isPaceAvailable() {
      pedometer.startUpdates(from: Date()) { [weak self] data, _ in
        guard let self, let pace = data?.currentPace?.doubleValue else { return }
        self.lock.withLock { self.estimator.paceReading(secondsPerMetre: pace) }
      }
    }
  }

  func stop() {
    motionManager.stopDeviceMotionUpdates()
    activityManager.stopActivityUpdates()
    pedometer.stopUpdates()
    lock.withLock {
      estimator = WalkingSpeedEstimator()
      steps = StepDetector()
    }
  }
}
