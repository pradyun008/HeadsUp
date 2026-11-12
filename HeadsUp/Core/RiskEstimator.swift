import Foundation

/// Which side of the CAMERA the object is predicted to be on at contact.
/// The camera follows the head, so this is head-relative, not body-relative.
/// It reports where the hazard is. It is never an instruction about where to move.
enum Side: String, Sendable {
  case left, ahead, right
}

enum CourseState: String, Sendable {
  /// Less than `minHistory` of sightings: no judgment yet.
  case tooNew
  /// Not growing in the image (or shrinking): not approaching.
  case notApproaching
  /// Growing, but predicted to slide out of the corridor before contact.
  case passing
  /// Growing and predicted to still overlap the corridor at contact.
  case onCourse
}

struct RiskAssessment: Equatable, Sendable {
  var trackID: Int
  var state: CourseState
  /// Estimated seconds to contact. An estimate from image growth only (no depth sensor).
  var tau: Double?
  /// 0 none, 1 low, 2 high, 3 urgent. Non-zero only when on course.
  var level: Int
  var side: Side?
  /// Predicted box edges at contact, camera-relative −1…+1 (may run past the frame).
  var predictedLeft: Double?
  var predictedRight: Double?
  /// True when this is the previous judgment carried over (head moving fast, or track coasting).
  var held = false
}

struct RiskFrame: Equatable, Sendable {
  var assessments: [RiskAssessment] = []
  /// True while the head is turning fast (or has just stopped): judgments are held, not updated.
  var unstable = false
  /// Global image shift rate, normalized x units per second.
  var shiftRate = 0.0

  subscript(trackID: Int) -> RiskAssessment? { assessments.first { $0.trackID == trackID } }
}

struct RiskConfig: Sendable, Equatable {
  /// Sightings must span at least this long before a track is judged.
  var minHistory = 0.4
  /// Half-width of the wearer's corridor in normalized x units.
  var corridor = 0.15
  /// Predicted centre beyond ±this is LEFT / RIGHT; inside is AHEAD.
  var sideThreshold = 0.15
  /// Expansion rates at or below this (per second) count as "not approaching".
  var minExpansionRate = 0.05
  /// tau above this → level 0.
  var tauLow = 4.0
  /// tau below this → level 2.
  var tauHigh = 2.5
  /// tau below this → level 3.
  var tauUrgent = 1.5
  /// Global shift faster than this (normalized x units per second) marks the frame unstable.
  var unstableShiftRate = 0.5
  /// Keep holding for this long after the last unstable frame.
  var settleTime = 0.3
}

/// Decides, per track, whether it is on a collision course and how soon.
///
/// The sailor's rule: constant bearing and decreasing range means collision.
///  - Decreasing range shows up as the box growing (looming); the growth rate gives time-to-contact.
///  - Constant bearing shows up as the box NOT sliding out of the corridor while it grows.
///
/// Known limitations (expected behaviour, not bugs):
///  - Walking toward any stationary object of a kept class directly in the path (a standing person,
///    a parked car) is a real relative approach and WILL trigger. Objects beside the path slide
///    toward the frame edge and are judged as passing.
///  - The corridor is centred on the camera, which points where the head points. The prototype
///    assumes the wearer is facing roughly the way they are walking.
///  - Head-motion handling is an approximation: one global image shift cannot account for rotation
///    plus objects at different depths. Its real job is to PAUSE judgment during fast head turns.
///    Tracking is not reliable through them.
///  - A box cut off by the frame edge stops growing in the image, so tau is overestimated for
///    objects that already fill the frame.
struct RiskEstimator: Sendable {
  var config = RiskConfig()

  private var previous: [Int: RiskAssessment] = [:]
  /// Cumulative global image shift at each recent frame time.
  private var shiftHistory: [(time: Double, total: Double)] = []
  private var totalShift = 0.0
  private var lastTime: Double?
  private var lastUnstable: Double?

  mutating func reset() {
    previous = [:]
    shiftHistory = []
    totalShift = 0
    lastTime = nil
    lastUnstable = nil
  }

  /// - Parameters:
  ///   - frameShift: how far the whole image content moved horizontally since the previous frame,
  ///     in normalized x units (positive = content moved right, i.e. the head turned left).
  mutating func update(tracks: [Track], time: Double, frameShift: Double) -> RiskFrame {
    let dt = lastTime.map { time - $0 } ?? 0
    lastTime = time
    totalShift += frameShift
    shiftHistory.append((time, totalShift))
    shiftHistory.removeAll { time - $0.time > 3 }

    let rate = dt > 0 ? abs(frameShift) / dt : 0
    if rate > config.unstableShiftRate { lastUnstable = time }
    let unstable = lastUnstable.map { time - $0 <= config.settleTime } ?? false

    var frame = RiskFrame(unstable: unstable, shiftRate: rate)
    var current: [Int: RiskAssessment] = [:]
    for track in tracks {
      var assessment: RiskAssessment
      if unstable || track.isCoasting {
        // Hold: keep the last judgment as it was. A track with no judgment yet stays at none.
        assessment = previous[track.id] ?? RiskAssessment(trackID: track.id, state: .tooNew, level: 0)
        assessment.held = true
      } else {
        assessment = assess(track, now: time)
      }
      current[track.id] = assessment
      frame.assessments.append(assessment)
    }
    previous = current
    return frame
  }

  private func assess(_ track: Track, now: Double) -> RiskAssessment {
    let obs = track.observations
    let span = track.historySpan
    guard obs.count >= 4, span >= config.minHistory - 1e-6 else {
      return RiskAssessment(trackID: track.id, state: .tooNew, level: 0)
    }
    let times = obs.map { $0.time - now }

    // Looming. s = sqrt(area); the slope of ln(s) over time is the expansion rate k.
    let k = Self.slope(times, obs.map { 0.5 * log(max($0.area, 1e-12)) })
    guard k > config.minExpansionRate else {
      return RiskAssessment(trackID: track.id, state: .notApproaching, level: 0)
    }
    // 1/k is the time-to-contact at the MIDDLE of the fitted window (ln(s) curves upward as the
    // object nears). Subtract half the window to bring the estimate to now.
    let tau = max(0.05, 1 / k - span / 2)

    // Collision course. Remove global head motion from the edges, then fit their velocities.
    let lefts = obs.map { $0.left + totalShift - shift(at: $0.time) }
    let rights = obs.map { $0.right + totalShift - shift(at: $0.time) }
    let vL = Self.slope(times, lefts), vR = Self.slope(times, rights)
    let predictedLeft = lefts[lefts.count - 1] + vL * tau
    let predictedRight = rights[rights.count - 1] + vR * tau
    let onCourse = predictedRight >= -config.corridor && predictedLeft <= config.corridor

    let center = (predictedLeft + predictedRight) / 2
    let side: Side = center < -config.sideThreshold ? .left : center > config.sideThreshold ? .right : .ahead

    return RiskAssessment(
      trackID: track.id, state: onCourse ? .onCourse : .passing, tau: tau,
      level: onCourse ? level(forTau: tau) : 0, side: side,
      predictedLeft: predictedLeft, predictedRight: predictedRight)
  }

  func level(forTau tau: Double) -> Int {
    if tau < config.tauUrgent { return 3 }
    if tau < config.tauHigh { return 2 }
    if tau <= config.tauLow { return 1 }
    return 0
  }

  /// Cumulative shift at a past frame time.
  private func shift(at time: Double) -> Double {
    for entry in shiftHistory.reversed() where entry.time <= time + 1e-9 { return entry.total }
    return shiftHistory.first?.total ?? totalShift
  }

  /// Least-squares slope of y against x.
  static func slope(_ x: [Double], _ y: [Double]) -> Double {
    let n = Double(x.count)
    guard x.count >= 2 else { return 0 }
    let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
    var sxy = 0.0, sxx = 0.0
    for i in x.indices {
      sxy += (x[i] - mx) * (y[i] - my)
      sxx += (x[i] - mx) * (x[i] - mx)
    }
    return sxx > 0 ? sxy / sxx : 0
  }
}
