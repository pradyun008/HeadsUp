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
  /// On course, but "Is it moving?" says the wearer is walking into something mostly still:
  /// its own speed stayed below `MeasuredConstants.movingCutoff`. Level 0 (the cane's job).
  case walkingInto
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
  /// True when this is the previous judgment carried over (head moving fast, track coasting, a
  /// suspicious size jump being checked, or history rebuilding after an accepted jump). While held,
  /// tau counts down by the time passed, so an on-course level can rise. After
  /// `MeasuredConstants.maxPause` of holding, the judgment is dropped (`.tooNew`, level 0).
  var held = false
  /// True when the box touches a frame edge and the level was kept from going down
  /// (a cut-off box stops growing, so tau reads too late exactly when the object is closest).
  var cutOffHold = false
  /// Estimated FORWARD distance in metres (along where the camera points), from box height,
  /// focal length and the class's typical height. Recomputed every frame for every track,
  /// even when the judgment above is held. An estimate (roughly ±20–30%), never a measurement.
  var distance: Double?
  /// False when the box touches the top or bottom of the frame: the object is cut off, so the
  /// box is too short and the distance reads too far. Later steps should not trust it.
  var distanceReliable = false
  /// "Is it moving?": the object's own speed toward the wearer in m/s, an estimate.
  /// closing speed (distance ÷ tau) − wearer speed. Set only for on-course objects with a
  /// reliable distance at some point. While the wearer is stationary this is the closing speed.
  var ownSpeed: Double?
}

struct RiskFrame: Equatable, Sendable {
  var assessments: [RiskAssessment] = []
  /// What the wearer was doing on this frame, as used by "Is it moving?".
  var wearer: WearerMotion = .stationary
  /// True while the head is turning fast (or has just stopped): judgments are held, not updated.
  var unstable = false
  /// Global image shift rate, normalized x units per second.
  var shiftRate = 0.0

  subscript(trackID: Int) -> RiskAssessment? { assessments.first { $0.trackID == trackID } }
}

struct RiskConfig: Sendable, Equatable, Codable {
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
///  - "Is it moving?" separates walking into a still object (a standing person, a parked car) from
///    an object moving toward the wearer, using estimated distance and the phone's walking speed.
///    Both are estimates (see `MeasuredConstants`), so it can still be wrong; it is built to err
///    toward warning. Objects beside the path slide toward the frame edge and are judged as passing.
///  - The corridor is centred on the camera, which points where the head points. The prototype
///    assumes the wearer is facing roughly the way they are walking.
///  - Head-motion handling is an approximation: one global image shift cannot account for rotation
///    plus objects at different depths. Its real job is to PAUSE judgment during fast head turns.
///    Tracking is not reliable through them.
///  - A box cut off by the frame edge stops growing in the image, so tau is overestimated for
///    objects that already fill the frame. Mitigation: while cut off, the level can't go down.
///  - A held tau counts down assuming the object keeps its speed. If it turned away during the
///    pause the level can rise for nothing, for at most `MeasuredConstants.maxPause`.
struct RiskEstimator: Sendable {
  var config = RiskConfig()

  private var previous: [Int: RiskAssessment] = [:]
  /// Cumulative global image shift at each recent frame time.
  private var shiftHistory: [(time: Double, total: Double)] = []
  private var totalShift = 0.0
  private var lastTime: Double?
  private var lastUnstable: Double?
  /// "Is it moving?": each track's most recent reliable distance (from a box that was not cut off).
  private var lastReliableDistance: [Int: Double] = [:]
  /// "Is it moving?": consecutive frames each track has been below the moving cutoff.
  private var framesBelowCutoff: [Int: Int] = [:]
  /// When each track's current hold (pause) began.
  private var pauseStart: [Int: Double] = [:]
  /// After a dropped judgment: only sightings after this time count toward the rebuilt one.
  private var freshSince: [Int: Double] = [:]

  mutating func reset() {
    previous = [:]
    shiftHistory = []
    totalShift = 0
    lastTime = nil
    lastUnstable = nil
    lastReliableDistance = [:]
    framesBelowCutoff = [:]
    pauseStart = [:]
    freshSince = [:]
  }

  /// - Parameters:
  ///   - frameShift: how far the whole image content moved horizontally since the previous frame,
  ///     in normalized x units (positive = content moved right, i.e. the head turned left).
  ///   - wearer: what the wearer is doing (from the phone's motion sensors). Defaults to stationary,
  ///     which makes "Is it moving?" treat anything on course as moving (the behaviour before it existed).
  mutating func update(
    tracks: [Track], time: Double, frameShift: Double, wearer: WearerMotion = .stationary
  ) -> RiskFrame {
    let dt = lastTime.map { time - $0 } ?? 0
    lastTime = time
    totalShift += frameShift
    shiftHistory.append((time, totalShift))
    shiftHistory.removeAll { time - $0.time > 3 }

    let rate = dt > 0 ? abs(frameShift) / dt : 0
    if rate > config.unstableShiftRate { lastUnstable = time }
    let unstable = lastUnstable.map { time - $0 <= config.settleTime } ?? false

    var frame = RiskFrame(unstable: unstable, shiftRate: rate)
    frame.wearer = wearer
    var current: [Int: RiskAssessment] = [:]
    for track in tracks {
      let id = track.id
      let prior = previous[id]
      // Pause: head turning fast, track coasting, or a suspicious size jump being checked.
      let paused = unstable || track.isCoasting || track.hasCandidate
      let fresh = paused ? nil : assess(track, now: time, since: freshSince[id])
      // Rebuilding: it had a judgment, but its history is too short right now (an accepted jump
      // replaced it, or a gap thinned it). Hold the old judgment instead of going blank.
      let rebuilding = fresh?.state == .tooNew && prior.map { $0.state != .tooNew } == true

      var assessment: RiskAssessment
      if paused || rebuilding {
        let start = pauseStart[id] ?? time
        pauseStart[id] = start
        if time - start >= MeasuredConstants.maxPause {
          // Paused too long: drop the judgment. No warnings about something we can't judge now;
          // it is rebuilt from sightings after this moment.
          assessment = RiskAssessment(trackID: id, state: .tooNew, level: 0)
          freshSince[id] = time
          framesBelowCutoff[id] = 0
        } else {
          // Hold the last judgment (including "Is it moving?"), with tau counting down by the time
          // passed, assuming the object keeps its speed. Only on-course levels follow the countdown,
          // so a hold never turns a passing object into a hazard. No judgment yet stays at none.
          assessment = prior ?? RiskAssessment(trackID: id, state: .tooNew, level: 0)
          if let tau = assessment.tau { assessment.tau = max(0.05, tau - dt) }
          if assessment.state == .onCourse, let tau = assessment.tau { assessment.level = level(forTau: tau) }
        }
        assessment.held = true
        assessment.cutOffHold = false
      } else {
        pauseStart[id] = nil
        assessment = fresh!
      }
      // Distance for every track, every frame (also when the judgment is held), from its current box.
      if let estimate = Self.distance(objectClass: track.objectClass, top: track.top, bottom: track.bottom) {
        assessment.distance = estimate.metres
        assessment.distanceReliable = estimate.reliable
        // Remember it for "Is it moving?" only when the box is real (not coasting) and not cut off.
        if estimate.reliable && !track.isCoasting { lastReliableDistance[track.id] = estimate.metres }
      } else {
        assessment.distance = nil
        assessment.distanceReliable = false
      }
      // Order per frame: Getting closer? → Heading at me? (both in `assess`) → Is it moving? → Soon enough?
      // (the level was set in `assess`; "Is it moving?" can only lower it to 0).
      if !assessment.held && assessment.state == .onCourse {
        isItMoving(&assessment, wearer: wearer)
      }
      // Cut-off hold: while the box touches a frame edge, its level can't go down (not even to
      // "walking into"): the box can't grow past the edge, so tau reads too late when it's closest.
      if !assessment.held, track.touchesFrameEdge, let prior, prior.level > assessment.level {
        assessment.level = prior.level
        assessment.state = prior.state
        assessment.side = prior.side
        if assessment.tau == nil { assessment.tau = prior.tau }
        if assessment.predictedLeft == nil {
          assessment.predictedLeft = prior.predictedLeft
          assessment.predictedRight = prior.predictedRight
        }
        assessment.cutOffHold = true
      }
      current[track.id] = assessment
      frame.assessments.append(assessment)
    }
    previous = current
    // Forget tracks that are gone.
    let ids = Set(tracks.map(\.id))
    lastReliableDistance = lastReliableDistance.filter { ids.contains($0.key) }
    framesBelowCutoff = framesBelowCutoff.filter { ids.contains($0.key) }
    pauseStart = pauseStart.filter { ids.contains($0.key) }
    freshSince = freshSince.filter { ids.contains($0.key) }
    return frame
  }

  /// "Is it moving?" for an on-course object: is IT moving toward the wearer, or is the wearer
  /// walking into something mostly still?
  ///
  ///   closing speed = distance ÷ tau      (tau = 1 ÷ expansion rate now, so this is expansion × distance)
  ///   its own speed = closing speed − wearer speed
  ///
  /// Distance is the track's last RELIABLE distance: for a cut-off box it is from an earlier frame,
  /// so it reads farther than the object is now, which errs toward "moving" (toward warning).
  /// If the object never had a reliable distance, it is never suppressed.
  private mutating func isItMoving(_ assessment: inout RiskAssessment, wearer: WearerMotion) {
    let id = assessment.trackID
    let closing = lastReliableDistance[id].flatMap { z in assessment.tau.map { z / $0 } }

    let wearerSpeed: Double
    switch wearer {
    case .stationary:
      // Standing still: anything growing on course is moving toward the wearer. No speed math.
      assessment.ownSpeed = closing
      framesBelowCutoff[id] = 0
      return
    case .walking(let speed, _):
      wearerSpeed = speed
    }

    guard let closing else {
      framesBelowCutoff[id] = 0  // never had a reliable distance: don't suppress (no misses)
      return
    }
    let ownSpeed = closing - wearerSpeed
    assessment.ownSpeed = ownSpeed

    if ownSpeed > MeasuredConstants.movingCutoff {
      framesBelowCutoff[id] = 0  // moving: back to alerting immediately
    } else {
      framesBelowCutoff[id, default: 0] += 1
    }
    if framesBelowCutoff[id, default: 0] >= MeasuredConstants.framesToSuppress {
      assessment.state = .walkingInto
      assessment.level = 0
    }
  }

  /// - Parameter since: only sightings after this time count (after a dropped judgment).
  private func assess(_ track: Track, now: Double, since: Double? = nil) -> RiskAssessment {
    let obs = since.map { cut in track.observations.filter { $0.time > cut } } ?? track.observations
    let span = (obs.last?.time ?? 0) - (obs.first?.time ?? 0)
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

  /// Forward distance from box height (similar triangles):
  ///   distance = focal length × typical real height ÷ box height
  /// `top` and `bottom` are in frame heights (0 = top of frame, 1 = bottom), the same units as
  /// `MeasuredConstants.focalLength`. Returns nil for a box with no height.
  static func distance(
    objectClass: ObjectClass, top: Double, bottom: Double,
    focalLength: Double = MeasuredConstants.focalLength
  ) -> (metres: Double, reliable: Bool)? {
    let boxHeight = bottom - top
    guard boxHeight > 1e-6 else { return nil }
    let metres = focalLength * MeasuredConstants.typicalHeight(of: objectClass) / boxHeight
    let margin = MeasuredConstants.cutOffMargin
    let cutOff = top <= margin || bottom >= 1 - margin
    return (metres, !cutOff)
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
