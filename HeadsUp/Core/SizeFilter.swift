import Foundation

/// A small Kalman filter that follows one object's box size, used ONLY to flag suspicious jumps
/// (two people merging into one box, someone stepping in front, a detector glitch).
/// It does not replace the tau fit: tau is still the least-squares fit in `RiskEstimator`,
/// it just leaves the flagged sightings out.
///
/// What it follows: u = 1 ÷ box size (box size = √area). At a steady closing speed, u falls in
/// a straight line (u is proportional to distance), so a "steady change" model fits it exactly,
/// and a fast real approach is predicted rather than flagged. State: u and its rate du/dt.
///
/// Each frame: predict u from the trend → compare the new box with the prediction. If it is
/// further off than noise can explain (more than `MeasuredConstants.jumpGate` × the expected
/// spread), the sighting is surprising. Noise is relative (a percentage of the box), so the same
/// settings work for near and far objects.
struct SizeFilter: Equatable, Sendable {
  /// 1 ÷ box size.
  private(set) var u: Double
  /// du/dt, per second.
  private(set) var rate: Double
  /// Covariance [[p00, p01], [p01, p11]]: how unsure the filter is about u and the rate.
  private var p00: Double
  private var p01: Double
  private var p11: Double
  /// Time of the last accepted sighting.
  private(set) var time: Double

  init(size: Double, time: Double) {
    u = 1 / max(size, 1e-6)
    rate = 0
    let r = MeasuredConstants.sizeJitter * u
    p00 = r * r
    p01 = 0
    // Rate unknown at the start: allow up to about 2× u per second (tau down to ~0.5 s).
    p11 = (2 * u) * (2 * u)
    self.time = time
  }

  /// Prediction at `time`: (u, variance of u).
  private func predicted(at t: Double) -> (u: Double, rate: Double, p00: Double, p01: Double, p11: Double) {
    let dt = max(0, t - time)
    // Process noise: how much the rate may wander (speeding up, slowing down), relative to u.
    let q = pow(MeasuredConstants.sizeRateNoise * u, 2)
    let n00 = p00 + 2 * dt * p01 + dt * dt * p11 + q * dt * dt * dt / 3
    let n01 = p01 + dt * p11 + q * dt * dt / 2
    let n11 = p11 + q * dt
    return (u + rate * dt, rate, n00, n01, n11)
  }

  /// How many standard deviations a box of `size` at `t` is away from the prediction.
  func surprise(size: Double, at t: Double) -> Double {
    let p = predicted(at: t)
    let z = 1 / max(size, 1e-6)
    let r = MeasuredConstants.sizeJitter * p.u
    let s = p.p00 + r * r
    return abs(z - p.u) / sqrt(max(s, 1e-18))
  }

  /// True when a box of `size` at `t` breaks from the trend more than noise can explain.
  func isSurprising(size: Double, at t: Double) -> Bool {
    surprise(size: size, at: t) > MeasuredConstants.jumpGate
  }

  /// Blend in an accepted sighting.
  mutating func update(size: Double, at t: Double) {
    let p = predicted(at: t)
    let z = 1 / max(size, 1e-6)
    let r = MeasuredConstants.sizeJitter * p.u
    let s = p.p00 + r * r
    let k0 = p.p00 / s, k1 = p.p01 / s
    let innovation = z - p.u
    u = p.u + k0 * innovation
    rate = p.rate + k1 * innovation
    p00 = (1 - k0) * p.p00
    p01 = (1 - k0) * p.p01
    p11 = p.p11 - k1 * p.p01
    time = t
  }
}
