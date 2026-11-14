import Foundation

/// One position report, from GPS or from a replayed trace.
struct LocationFix: Equatable, Sendable {
  var point: GeoPoint
  /// Horizontal accuracy in metres (the radius the true position is probably inside).
  var accuracy: Double = 5
  /// Compass heading of the phone in degrees, if known. Unreliable when the phone is in a pocket.
  var heading: Double? = nil
  /// Compass accuracy in degrees. Negative or nil means the heading is not usable.
  var headingAccuracy: Double? = nil
  /// Seconds on any steady clock. Only differences are used.
  var time: Double
}

/// A walking route, reduced to what the engine needs.
struct NavRoute: Sendable {
  /// A point where one route step ends and the next begins. Whether it is a turn, and which way,
  /// is worked out from the shape of the line, never from the map service's instruction text.
  struct Junction: Sendable {
    /// Distance along the route.
    var along: Double
    /// Street the route follows after this point, if known ("Nassau Street").
    var street: String? = nil
    /// True only when an aerial image showed a marked crosswalk here. False means "not known",
    /// never "there is no crosswalk".
    var crosswalk = false
  }

  var path: RoutePath
  var junctions: [Junction] = []
  /// Street the route starts on, if known.
  var startStreet: String? = nil
  var destinationName: String
  /// Where the destination itself is, used only to say which side it is on.
  var destination: GeoPoint? = nil
}

struct NavConfig: Sendable, Equatable {
  /// Distance before a turn for the advance notice. About 150 ft.
  var advanceMetres = 46.0
  /// Distance before a turn for "Turn left". About 30 ft: one GPS fix per second at walking
  /// pace moves about 5 ft, and the words take a moment to say.
  var imminentMetres = 9.0
  /// A direction change smaller than this is not announced as a turn.
  var minTurnDegrees = 30.0
  /// A direction change larger than this is "turn around".
  var aroundDegrees = 150.0
  /// A turn counts as done once the wearer is this far past it along the route.
  var passMetres = 8.0
  /// Farther than this from the route line counts as off route. GPS between buildings drifts 5–10 m.
  var offRouteMetres = 25.0
  /// Off route for this long before a new route is requested.
  var offRouteSeconds = 10.0
  var arrivalMetres = 15.0
  /// "Continue straight" is said after this much walking with no other cue. About 200 ft.
  var reassuranceMetres = 61.0
  /// The compass is trusted for the clock-direction start cue only when it is at least this accurate.
  var maxHeadingError = 25.0
  /// Fixes less accurate than this are ignored.
  var maxFixError = 50.0
}

/// Something for the navigation voice to say.
///
/// These are wayfinding cues ("turn left"). They never say that anything is safe or clear;
/// live hazards are reported separately by the hazard loop, which always speaks first.
struct NavCue: Equatable, Sendable {
  enum Kind: String, Sendable {
    case start, wrongWay, advance, imminent, afterTurn, reassurance, reroute, arrival
  }
  var kind: Kind
  var text: String
  /// Which turn this cue is about, for cues about a turn.
  var maneuver: Int? = nil
}

/// Turns positions into spoken cues for one route. Pure logic: no MapKit, no clock, no speech.
struct NavigationEngine: Sendable {
  enum Phase: Equatable, Sendable {
    case idle
    case guiding
    /// Off the route for too long. The caller must fetch a new route and call `start(_:)`.
    case needsReroute
    case arrived
  }

  enum Direction: String, Sendable { case left, right, around }

  struct Maneuver: Sendable {
    var along: Double
    var direction: Direction
    var street: String?
    var crosswalk: Bool
    var advanceSaid = false
    var imminentSaid = false
    var passed = false
  }

  var config = NavConfig()
  private(set) var phase = Phase.idle
  private(set) var route: NavRoute?
  private(set) var maneuvers: [Maneuver] = []
  /// Distance walked along the route, from the latest usable fix.
  private(set) var along = 0.0
  /// Distance from the route line at the latest usable fix.
  private(set) var offset = 0.0

  private var firstFix: LocationFix?
  private var startSaid = false
  private var needsWrongWayCheck = false
  private var offRouteSince: Double?
  private var lastCueAlong = 0.0

  init(config: NavConfig = NavConfig()) { self.config = config }

  /// Begin guiding along a route. Also used for the new route after "Rerouting".
  mutating func start(_ route: NavRoute) {
    self.route = route
    maneuvers = route.junctions.compactMap { junction in
      // A junction at the very start or end has no "before" or "after" to compare.
      guard junction.along > 3, junction.along < route.path.length - 3 else { return nil }
      let turn = route.path.turn(at: junction.along)
      guard abs(turn) >= config.minTurnDegrees else { return nil }
      let direction: Direction = abs(turn) > config.aroundDegrees ? .around : (turn > 0 ? .right : .left)
      return Maneuver(along: junction.along, direction: direction, street: junction.street, crosswalk: junction.crosswalk)
    }.sorted { $0.along < $1.along }
    phase = .guiding
    along = 0
    offset = 0
    firstFix = nil
    startSaid = false
    needsWrongWayCheck = false
    offRouteSince = nil
    lastCueAlong = 0
  }

  mutating func stop() {
    phase = .idle
    route = nil
    maneuvers = []
  }

  /// Marks turns where an aerial image showed a crosswalk. Call any time before the turn is announced.
  mutating func setCrosswalk(_ found: Bool, nearAlong along: Double, tolerance: Double = 5) {
    for i in maneuvers.indices where abs(maneuvers[i].along - along) <= tolerance {
      maneuvers[i].crosswalk = found
    }
  }

  /// The next turn not yet passed, and how far away it is.
  var nextManeuver: (index: Int, distance: Double)? {
    guard let i = maneuvers.firstIndex(where: { !$0.passed }) else { return nil }
    return (i, maneuvers[i].along - along)
  }

  var distanceToDestination: Double { max(0, (route?.path.length ?? 0) - along) }

  /// Feed one position. Returns the cues to say now, usually none.
  mutating func update(_ fix: LocationFix) -> [NavCue] {
    guard phase == .guiding, let route else { return [] }
    guard fix.accuracy >= 0, fix.accuracy <= config.maxFixError else { return [] }

    // Where on the route is this? Look near the last position first, then anywhere.
    guard var snap = route.path.snap(fix.point, near: firstFix == nil ? nil : along) else { return [] }
    if snap.offset > config.offRouteMetres, let anywhere = route.path.snap(fix.point), anywhere.offset < snap.offset {
      snap = anywhere
    }
    offset = snap.offset

    if snap.offset > config.offRouteMetres {
      // Off the line. Wait before rerouting: GPS often wanders for a few seconds.
      if firstFix == nil { firstFix = fix }
      let since = offRouteSince ?? fix.time
      offRouteSince = since
      if fix.time - since >= config.offRouteSeconds {
        phase = .needsReroute
        return [NavCue(kind: .reroute, text: "Rerouting.")]
      }
      return []
    }
    offRouteSince = nil
    along = snap.along

    var cues: [NavCue] = []

    if !startSaid {
      startSaid = true
      firstFix = fix
      lastCueAlong = along
      needsWrongWayCheck = !compassUsable(fix)
      cues.append(startCue(fix))
    } else if needsWrongWayCheck, let first = firstFix, Geo.distance(first.point, fix.point) >= 10 {
      // The compass was not usable for the start cue, so check the walking direction once,
      // from GPS movement, after the first few steps.
      needsWrongWayCheck = false
      let walked = Geo.bearing(first.point, fix.point)
      let wanted = route.path.bearing(from: along, to: min(route.path.length, along + 15))
      if abs(Geo.turn(from: walked, to: wanted)) > 120 {
        cues.append(NavCue(kind: .wrongWay, text: "Route is behind you."))
      }
    }

    if distanceToDestination <= config.arrivalMetres {
      phase = .arrived
      return cues + [NavCue(kind: .arrival, text: arrivalText())]
    }

    // Turns the wearer has now gone past.
    for i in maneuvers.indices where !maneuvers[i].passed && along > maneuvers[i].along + config.passMetres {
      maneuvers[i].passed = true
      if let cue = afterTurnCue(i) { cues.append(cue) }
    }

    if let (i, distance) = nextManeuver {
      let legStart = i > 0 ? maneuvers[i - 1].along : 0
      if distance <= config.imminentMetres {
        if !maneuvers[i].imminentSaid {
          maneuvers[i].imminentSaid = true
          maneuvers[i].advanceSaid = true
          cues.append(NavCue(kind: .imminent, text: imminentText(i), maneuver: i))
        }
      } else if distance <= config.advanceMetres, !maneuvers[i].advanceSaid {
        maneuvers[i].advanceSaid = true
        // A leg shorter than the advance distance gets no advance notice, only "Turn left".
        if maneuvers[i].along - legStart >= config.advanceMetres {
          cues.append(NavCue(kind: .advance, text: advanceText(i, distance: distance), maneuver: i))
        }
      }
    }

    if !cues.isEmpty {
      lastCueAlong = along
    } else if along - lastCueAlong >= config.reassuranceMetres, let text = reassuranceText() {
      lastCueAlong = along
      cues.append(NavCue(kind: .reassurance, text: text))
    }
    return cues
  }

  /// The same cue, worded for where the wearer is now. Use this when a cue was cut off or
  /// delayed by a hazard warning, so a stale distance is never spoken.
  /// Returns nil when the cue no longer applies (the turn has been passed, or is now too close
  /// for an advance notice).
  func refreshed(_ cue: NavCue) -> NavCue? {
    switch cue.kind {
    case .start, .wrongWay, .reroute, .arrival:
      return cue
    case .advance:
      guard let i = cue.maneuver, maneuvers.indices.contains(i), !maneuvers[i].passed else { return nil }
      let distance = maneuvers[i].along - along
      guard distance > config.imminentMetres else { return nil }
      return NavCue(kind: .advance, text: advanceText(i, distance: distance), maneuver: i)
    case .imminent:
      guard let i = cue.maneuver, maneuvers.indices.contains(i), !maneuvers[i].passed else { return nil }
      return cue
    case .afterTurn:
      guard let i = cue.maneuver, let fresh = afterTurnCue(i) else { return nil }
      return fresh
    case .reassurance:
      return reassuranceText().map { NavCue(kind: .reassurance, text: $0) }
    }
  }

  // MARK: Wording

  private func startCue(_ fix: LocationFix) -> NavCue {
    guard let route else { return NavCue(kind: .start, text: "Start walking.") }
    let street = route.startStreet
    let routeBearing = route.path.bearing(from: along, to: min(route.path.length, along + 15))
    if let heading = fix.heading, compassUsable(fix) {
      // Clock direction relative to the way the PHONE points. Only trusted when the compass says it is accurate.
      let hour = Geo.clock(heading: heading, bearing: routeBearing)
      let onStreet = street.map { ", on \($0)" } ?? ""
      return NavCue(kind: .start, text: "Route starts at your \(hour) o'clock\(onStreet).")
    }
    return NavCue(kind: .start, text: street.map { "Head toward \($0)." } ?? "Start walking.")
  }

  private func compassUsable(_ fix: LocationFix) -> Bool {
    guard fix.heading != nil, let error = fix.headingAccuracy else { return false }
    return error >= 0 && error <= config.maxHeadingError
  }

  private func turnPhrase(_ maneuver: Maneuver) -> String {
    switch maneuver.direction {
    case .left: return "turn left"
    case .right: return "turn right"
    case .around: return "turn around"
    }
  }

  private func advanceText(_ i: Int, distance: Double) -> String {
    let m = maneuvers[i]
    var text = "In about \(Geo.spokenFeet(metres: distance)) feet, \(turnPhrase(m))"
    if m.crosswalk {
      // Reports what an aerial photo showed. It says nothing about traffic or signals.
      text += " at a marked crosswalk"
    } else if let street = m.street, m.direction != .around {
      text += " onto \(street)"
    }
    return text + "."
  }

  private func imminentText(_ i: Int) -> String {
    let phrase = turnPhrase(maneuvers[i])
    return phrase.prefix(1).uppercased() + phrase.dropFirst() + "."
  }

  /// Distance from the current position to the next turn, or to the destination on the last leg.
  private var distanceToNextTarget: Double {
    nextManeuver?.distance ?? distanceToDestination
  }

  private func afterTurnCue(_ i: Int) -> NavCue? {
    guard maneuvers.indices.contains(i), maneuvers[i].passed else { return nil }
    // Only while this is still the most recent turn.
    guard maneuvers.lastIndex(where: { $0.passed }) == i else { return nil }
    let distance = distanceToNextTarget
    guard distance >= 15 else { return nil }
    return NavCue(kind: .afterTurn, text: "Walk straight for \(Geo.spokenFeet(metres: distance)) feet.", maneuver: i)
  }

  private func reassuranceText() -> String? {
    let distance = distanceToNextTarget
    // Not when the advance notice or the arrival is about to be said anyway.
    guard distance > config.advanceMetres + 15 else { return nil }
    return "Continue straight, \(Geo.spokenFeet(metres: distance)) feet."
  }

  private func arrivalText() -> String {
    guard let route else { return "You have arrived." }
    var text = "You have arrived at \(route.destinationName)"
    if let destination = route.destination, route.path.length > 10 {
      // Which side of the final stretch the destination sits on. Left out when it is on the line.
      let end = route.path.point(at: route.path.length)
      let bearing = route.path.bearing(from: route.path.length - 10, to: route.path.length)
      let toDestination = Geo.bearing(end, destination)
      let sideways = Geo.distance(end, destination) * sin(Geo.turn(from: bearing, to: toDestination) * .pi / 180)
      if sideways > 5 { text += ", on your right" }
      if sideways < -5 { text += ", on your left" }
    }
    return text + "."
  }
}
