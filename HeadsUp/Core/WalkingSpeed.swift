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

/// Feeds Apple's activity labels and pedometer pace into a `WalkingSpeedEstimator`.
/// Needs the Motion & Fitness permission (NSMotionUsageDescription). If the phone can't provide
/// activity or pace, the wearer simply stays `.stationary` (subtract nothing: no misses).
final class MotionSource: @unchecked Sendable {
  private let activityManager = CMMotionActivityManager()
  private let pedometer = CMPedometer()
  private let queue = OperationQueue()
  private let lock = NSLock()
  private var estimator = WalkingSpeedEstimator()

  /// Safe to read from any thread (the pipeline reads it once per frame).
  var current: WearerMotion { lock.withLock { estimator.current } }

  func start() {
    lock.withLock { estimator = WalkingSpeedEstimator() }
    if CMMotionActivityManager.isActivityAvailable() {
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
    activityManager.stopActivityUpdates()
    pedometer.stopUpdates()
    lock.withLock { estimator = WalkingSpeedEstimator() }
  }
}
