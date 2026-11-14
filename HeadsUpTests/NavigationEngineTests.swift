import XCTest
@testable import HeadsUp

/// Navigation maths and cue timing, tested with synthetic walks (no GPS, no MapKit).
final class NavigationEngineTests: XCTestCase {
  private let origin = GeoPoint(lat: 40.3500, lon: -74.6590)

  /// A point `east` and `north` metres from the test origin.
  private func at(_ east: Double, _ north: Double) -> GeoPoint { Geo.point(from: origin, east: east, north: north) }

  /// North 150 m, right turn, east 120 m, right turn, south 60 m. Destination 8 m east of the end.
  private func blockRoute() -> NavRoute {
    NavRoute(
      path: RoutePath([at(0, 0), at(0, 150), at(120, 150), at(120, 90)]),
      junctions: [.init(along: 150, street: "Witherspoon Street"), .init(along: 270)],
      startStreet: "Nassau Street",
      destinationName: "McDonald's",
      destination: at(128, 90))
  }

  /// One fix per second walking the whole path at 1.4 m/s, `side` metres to the right of the line
  /// (the kind of steady error GPS has beside buildings).
  private func walk(_ path: RoutePath, side: Double = 0, speed: Double = 1.4) -> [LocationFix] {
    var fixes: [LocationFix] = []
    var along = 0.0, time = 0.0
    while along <= path.length {
      let bearing = path.bearing(from: max(0, along - 1), to: min(path.length, along + 1)) * .pi / 180
      let p = path.point(at: along)
      // Right of the direction of travel is (cos b, -sin b) in east/north.
      fixes.append(LocationFix(point: Geo.point(from: p, east: side * cos(bearing), north: -side * sin(bearing)), time: time))
      along += speed
      time += 1
    }
    return fixes
  }

  /// Runs fixes through an engine and records each cue with the route distance where it was said.
  private func run(_ route: NavRoute, _ fixes: [LocationFix]) -> (cues: [(cue: NavCue, along: Double)], engine: NavigationEngine) {
    var engine = NavigationEngine()
    engine.start(route)
    var out: [(NavCue, Double)] = []
    for fix in fixes {
      for cue in engine.update(fix) { out.append((cue, engine.along)) }
    }
    return (out, engine)
  }

  // 1. Snapping: a point beside the line maps to the right distance along the route.
  func testSnapFindsDistanceAlongAndOffset() {
    let path = blockRoute().path
    let snap = path.snap(at(8, 100))!
    XCTAssertEqual(snap.along, 100, accuracy: 0.5)
    XCTAssertEqual(snap.offset, 8, accuracy: 0.5)
    // On the second leg.
    let second = path.snap(at(50, 146))!
    XCTAssertEqual(second.along, 200, accuracy: 0.5)
    XCTAssertEqual(second.offset, 4, accuracy: 0.5)
    XCTAssertEqual(path.length, 330, accuracy: 0.5)
  }

  // 2. Left, right, continue and turn-around come from the shape of the line.
  func testTurnDirectionComesFromGeometry() {
    func directions(_ points: [GeoPoint], junctionAt along: Double) -> [NavigationEngine.Direction] {
      var engine = NavigationEngine()
      engine.start(NavRoute(path: RoutePath(points), junctions: [.init(along: along)], destinationName: "x"))
      return engine.maneuvers.map(\.direction)
    }
    XCTAssertEqual(directions([at(0, 0), at(0, 100), at(100, 100)], junctionAt: 100), [.right])
    XCTAssertEqual(directions([at(0, 0), at(0, 100), at(-100, 100)], junctionAt: 100), [.left])
    // A 20° bend is not announced.
    XCTAssertEqual(directions([at(0, 0), at(0, 100), at(34, 194)], junctionAt: 100), [])
    // Doubling back.
    XCTAssertEqual(directions([at(0, 0), at(0, 100), at(2, 0)], junctionAt: 100), [.around])
    // A corner drawn as several short segments still reads as one right turn.
    XCTAssertEqual(directions([at(0, 0), at(0, 97), at(1, 99), at(3, 100), at(100, 100)], junctionAt: 100), [.right])
  }

  // 3. Feet for speech: nearest 10 below 100 ft, nearest 50 above.
  func testSpokenFeetRounding() {
    XCTAssertEqual(Geo.spokenFeet(metres: 87 / Geo.feetPerMetre), 90)
    XCTAssertEqual(Geo.spokenFeet(metres: 149 / Geo.feetPerMetre), 150)
    XCTAssertEqual(Geo.spokenFeet(metres: 412 / Geo.feetPerMetre), 400)
    XCTAssertEqual(Geo.spokenFeet(metres: 24 / Geo.feetPerMetre), 20)
  }

  // 4. Clock direction from the phone's heading and the route's bearing.
  func testClockDirection() {
    XCTAssertEqual(Geo.clock(heading: 0, bearing: 0), 12)
    XCTAssertEqual(Geo.clock(heading: 0, bearing: 90), 3)
    XCTAssertEqual(Geo.clock(heading: 0, bearing: 180), 6)
    XCTAssertEqual(Geo.clock(heading: 0, bearing: 270), 9)
    XCTAssertEqual(Geo.clock(heading: 350, bearing: 50), 2)
    XCTAssertEqual(Geo.clock(heading: 90, bearing: 80), 12)
  }

  // 5. A recorded walk around one block, replayed from GPX: every cue once, in order, at the right place.
  func testReplayedWalkAroundBlockGivesCuesInOrder() throws {
    let route = blockRoute()
    // Save the walk as GPX and read it back, so the replay file format is tested too.
    let gpx = GPX.write(walk(route.path, side: 4))
    let fixes = GPX.parse(Data(gpx.utf8))
    XCTAssertGreaterThan(fixes.count, 200)
    XCTAssertEqual(fixes[10].time, 10, accuracy: 0.01)

    let (cues, engine) = run(route, fixes)
    XCTAssertEqual(
      cues.map(\.cue.text),
      [
        "Head toward Nassau Street.",
        "Continue straight, 300 feet.",
        "In about 150 feet, turn right onto Witherspoon Street.",
        "Turn right.",
        "Walk straight for 350 feet.",
        "In about 150 feet, turn right.",
        "Turn right.",
        "Walk straight for 150 feet.",
        "You have arrived at McDonald's, on your left.",
      ])
    XCTAssertEqual(engine.phase, .arrived)

    // Within 30 ft (9 m) of the intended distances before each turn.
    let advance = cues.filter { $0.cue.kind == .advance }.map(\.along)
    XCTAssertEqual(advance[0], 150 - 46, accuracy: 9)
    XCTAssertEqual(advance[1], 270 - 46, accuracy: 9)
    let imminent = cues.filter { $0.cue.kind == .imminent }.map(\.along)
    XCTAssertEqual(imminent[0], 150 - 9, accuracy: 9)
    XCTAssertEqual(imminent[1], 270 - 9, accuracy: 9)
    XCTAssertLessThan(imminent[0], 150)
    XCTAssertLessThan(imminent[1], 270)
  }

  // 6. Off the route for 9 s does not reroute; 11 s does, once.
  func testRerouteOnlyAfterTenSecondsOffRoute() {
    func fixes(offRouteSeconds: Int) -> [LocationFix] {
      var out = (0..<20).map { LocationFix(point: at(0, Double($0) * 1.4), time: Double($0)) }
      // 30 m to the side of the line.
      out += (0..<offRouteSeconds).map { LocationFix(point: at(30, 28), time: 20 + Double($0)) }
      out += (0..<5).map { LocationFix(point: at(0, 30 + Double($0) * 1.4), time: Double(20 + offRouteSeconds + $0)) }
      return out
    }
    let short = run(blockRoute(), fixes(offRouteSeconds: 10))  // fixes at 0...9 s after leaving
    XCTAssertFalse(short.cues.contains { $0.cue.kind == .reroute })
    XCTAssertEqual(short.engine.phase, .guiding)

    let long = run(blockRoute(), fixes(offRouteSeconds: 12))
    XCTAssertEqual(long.cues.filter { $0.cue.kind == .reroute }.count, 1)
    XCTAssertEqual(long.engine.phase, .needsReroute)
    // Nothing more is said until a new route is started.
    XCTAssertEqual(long.cues.last?.cue.text, "Rerouting.")
  }

  // 7. A leg shorter than 150 ft gets no advance notice, only "Turn left".
  func testShortLegSkipsAdvanceNotice() {
    let route = NavRoute(
      path: RoutePath([at(0, 0), at(0, 100), at(-30, 100), at(-30, 200)]),
      junctions: [.init(along: 100), .init(along: 130)],
      destinationName: "the library")
    let cues = run(route, walk(route.path)).cues.map(\.cue.text)
    XCTAssertEqual(
      cues,
      [
        "Start walking.",
        "In about 150 feet, turn left.",
        "Turn left.",
        "Walk straight for 70 feet.",
        "Turn right.",
        "Walk straight for 300 feet.",
        "You have arrived at the library.",
      ])
  }

  func testStartCueUsesClockOnlyWhenCompassIsAccurate() {
    // Route goes north; the phone points west, so the route is at 3 o'clock.
    var good = LocationFix(point: at(0, 0), time: 0)
    good.heading = 270
    good.headingAccuracy = 10
    XCTAssertEqual(run(blockRoute(), [good]).cues.first?.cue.text, "Route starts at your 3 o'clock, on Nassau Street.")

    var poor = good
    poor.headingAccuracy = 60
    XCTAssertEqual(run(blockRoute(), [poor]).cues.first?.cue.text, "Head toward Nassau Street.")
  }

  func testWalkingTheWrongWayIsReportedOnce() {
    // No compass. The route goes north but the wearer walks south.
    let fixes = (0..<12).map { LocationFix(point: at(0, -Double($0) * 1.4), time: Double($0)) }
    let cues = run(blockRoute(), fixes).cues.map(\.cue.text)
    XCTAssertEqual(cues, ["Head toward Nassau Street.", "Route is behind you."])
  }

  func testCrosswalkIsMentionedOnlyWhenFound() {
    var route = blockRoute()
    route.junctions[0].crosswalk = true
    let cues = run(route, walk(route.path)).cues.map(\.cue.text)
    XCTAssertTrue(cues.contains("In about 150 feet, turn right at a marked crosswalk."))
    // The second turn has no detection: nothing extra is said, and never "no crosswalk".
    XCTAssertTrue(cues.contains("In about 150 feet, turn right."))
    XCTAssertFalse(cues.contains { $0.lowercased().contains("no crosswalk") })
  }

  // A cue delayed by a hazard warning is re-worded for the current position, or dropped.
  func testRefreshedCueHasFreshDistanceOrIsDropped() {
    var engine = NavigationEngine()
    engine.start(blockRoute())
    var advance: NavCue?
    var time = 0.0
    func feed(to north: Double) {
      var y = engine.along
      while y < north {
        y += 1.4
        time += 1
        for cue in engine.update(LocationFix(point: at(0, y), time: time)) where cue.kind == .advance { advance = cue }
      }
    }
    feed(to: 106)
    XCTAssertEqual(advance?.text, "In about 150 feet, turn right onto Witherspoon Street.")
    // About 20 m later (23 m, or 75 ft, before the turn) the same cue gives a smaller distance.
    feed(to: 126)
    XCTAssertEqual(engine.refreshed(advance!)?.text, "In about 70 feet, turn right onto Witherspoon Street.")
    // Too close for an advance notice: dropped ("Turn right" covers it).
    feed(to: 144)
    XCTAssertNil(engine.refreshed(advance!))
  }

  func testInaccurateFixesAreIgnored() {
    var engine = NavigationEngine()
    engine.start(blockRoute())
    XCTAssertEqual(engine.update(LocationFix(point: at(0, 0), accuracy: 120, time: 0)), [])
    XCTAssertEqual(engine.update(LocationFix(point: at(0, 0), accuracy: 8, time: 1)).map(\.kind), [.start])
  }
}
