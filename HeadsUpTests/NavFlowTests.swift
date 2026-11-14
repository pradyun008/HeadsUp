import XCTest
@testable import HeadsUp

// 11. The spoken request parser.
final class VoiceCommandTests: XCTestCase {
  func testDestinationPhrases() {
    XCTAssertEqual(VoiceCommand.parse("I want to go to McDonald's"), .destination("mcdonald's"))
    XCTAssertEqual(VoiceCommand.parse("Take me to the nearest coffee shop."), .destination("coffee shop"))
    XCTAssertEqual(VoiceCommand.parse("um navigate to Rabinowitz Hall please"), .destination("rabinowitz hall"))
    XCTAssertEqual(VoiceCommand.parse("McDonald’s"), .destination("mcdonald's"))
    // "stop" inside a destination is not the stop command.
    XCTAssertEqual(VoiceCommand.parse("Take me to the bus stop"), .destination("bus stop"))
  }

  func testStopAndNoise() {
    XCTAssertEqual(VoiceCommand.parse("Stop"), .stop)
    XCTAssertEqual(VoiceCommand.parse("cancel navigation"), .stop)
    XCTAssertEqual(VoiceCommand.parse(""), .none)
    XCTAssertEqual(VoiceCommand.parse("uh"), .none)
    XCTAssertEqual(VoiceCommand.parse("take me to"), .none)
  }
}

final class RouteAdapterTests: XCTestCase {
  private let origin = GeoPoint(lat: 40.3500, lon: -74.6590)
  private func at(_ east: Double, _ north: Double) -> GeoPoint { Geo.point(from: origin, east: east, north: north) }

  // Each map step's instruction happens at the end of its line. Direction comes from the line,
  // so a wrong word in the text cannot send the wearer the wrong way.
  func testJunctionsComeFromStepEndsAndDirectionFromGeometry() {
    let route = NavRoute(
      steps: [
        RouteStep(points: [at(0, 0)], instruction: "Proceed to the route"),
        // The line turns LEFT at the end of this step, whatever the text says.
        RouteStep(points: [at(0, 0), at(0, 100)], instruction: "Take a right onto Nassau St"),
        RouteStep(points: [at(0, 100), at(-80, 100)], instruction: "Take a right onto the path"),
        RouteStep(points: [at(-80, 100), at(-80, 160)], instruction: "The destination is on your left"),
      ],
      destinationName: "the library", destination: at(-88, 160))
    XCTAssertEqual(route.path.length, 240, accuracy: 0.5)
    XCTAssertEqual(route.junctions.map { $0.along.rounded() }, [0, 100, 180])
    XCTAssertEqual(route.junctions.map(\.street), [nil, "Nassau Street", nil])

    var engine = NavigationEngine()
    engine.start(route)
    XCTAssertEqual(engine.maneuvers.map(\.direction), [.left, .right])
    XCTAssertEqual(engine.maneuvers.first?.street, "Nassau Street")
  }

  func testSpokenSummary() {
    func candidate(metres: Double, minutes: Int) -> DestinationCandidate {
      DestinationCandidate(
        name: "McDonald's", street: "Nassau Street", point: origin,
        route: NavRoute(path: RoutePath([origin, at(0, 100)]), destinationName: "McDonald's"),
        distanceMetres: metres, minutes: minutes)
    }
    XCTAssertEqual(candidate(metres: 1287, minutes: 17).spokenSummary, "McDonald's on Nassau Street, about 0.8 miles, 17 minutes.")
    XCTAssertEqual(candidate(metres: 120, minutes: 1).spokenSummary, "McDonald's on Nassau Street, about 400 feet, 1 minute.")
  }
}

/// The button, confirmation and guidance flow, with fake listening, search and GPS.
@MainActor
final class NavControllerTests: XCTestCase {
  private final class FakeLocation: LocationProvider {
    var onFix: ((LocationFix) -> Void)?
    var onProblem: ((String?) -> Void)?
    func start() {}
    func stop() {}
  }

  private let origin = GeoPoint(lat: 40.3500, lon: -74.6590)
  private func at(_ east: Double, _ north: Double) -> GeoPoint { Geo.point(from: origin, east: east, north: north) }

  private func candidate(_ name: String, minutes: Int) -> DestinationCandidate {
    DestinationCandidate(
      name: name, street: "Nassau Street", point: at(100, 150),
      route: NavRoute(path: RoutePath([at(0, 0), at(0, 150), at(100, 150)]), junctions: [.init(along: 150)], destinationName: name),
      distanceMetres: 250, minutes: minutes)
  }

  private func pause(_ seconds: Double = 0.05) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

  private func makeController(heard: String?) -> (NavController, FakeLocation, spoken: () -> [String]) {
    let location = FakeLocation()
    let nav = NavController(location: location)
    var spoken: [String] = []
    nav.speakCue = { spoken.append($0.text) }
    nav.speakNotice = { spoken.append($0) }
    nav.listen = { heard }
    nav.cancelListen = {}
    nav.search = { _, _ in [self.candidate("McDonald's", minutes: 4), self.candidate("McDonald's Express", minutes: 9)] }
    nav.confirmSeconds = 0.05
    nav.activate()
    location.onFix?(LocationFix(point: at(0, 0), time: 0))
    return (nav, location, { spoken })
  }

  func testRequestIsConfirmedThenGuidanceStartsByItself() async {
    let (nav, location, spoken) = makeController(heard: "I want to go to McDonald's")
    nav.buttonPressed()
    await pause()
    XCTAssertEqual(nav.state, .confirming)
    XCTAssertEqual(spoken().last, "McDonald's on Nassau Street, about 0.2 miles, 4 minutes. Starting.")

    // The countdown starts once the sentence has been spoken; no press means "yes".
    nav.spoke(spoken().last!)
    await pause(0.2)
    XCTAssertEqual(nav.state, .guiding)
    XCTAssertEqual(spoken().last, "Start walking.")

    // Guidance cues follow the position.
    for i in 1...80 { location.onFix?(LocationFix(point: at(0, Double(i) * 1.4), time: Double(i))) }
    XCTAssertTrue(spoken().contains("In about 150 feet, turn right."))
    XCTAssertEqual(nav.feetToNextTurn, 100)  // 38 m is 125 ft, spoken to the nearest 50
  }

  func testButtonDuringConfirmationReadsTheNextResult() async {
    let (nav, _, spoken) = makeController(heard: "take me to mcdonald's")
    nav.buttonPressed()
    await pause()
    nav.buttonPressed()
    XCTAssertEqual(nav.state, .confirming)
    XCTAssertEqual(spoken().last, "McDonald's Express on Nassau Street, about 0.2 miles, 9 minutes. Starting.")
    nav.buttonPressed()
    XCTAssertEqual(nav.state, .idle)
    XCTAssertEqual(spoken().last, "No more results.")
    // The rejected destination never starts.
    await pause(0.2)
    XCTAssertEqual(nav.state, .idle)
  }

  func testSayingStopEndsNavigation() async {
    let (nav, _, spoken) = makeController(heard: "take me to mcdonald's")
    nav.buttonPressed()
    await pause()
    nav.spoke(spoken().last!)
    await pause(0.2)
    XCTAssertEqual(nav.state, .guiding)

    nav.listen = { "stop" }
    nav.buttonPressed()
    await pause()
    XCTAssertEqual(nav.state, .idle)
    XCTAssertEqual(spoken().last, "Navigation stopped.")
  }

  func testUnclearRequestAndNoResults() async {
    let (nav, _, spoken) = makeController(heard: "uh")
    nav.buttonPressed()
    await pause()
    XCTAssertEqual(spoken().last, "Didn't catch that.")
    XCTAssertEqual(nav.state, .idle)

    nav.listen = { "take me to atlantis" }
    nav.search = { _, _ in [] }
    nav.buttonPressed()
    await pause()
    XCTAssertEqual(spoken().last, "No results for atlantis.")
    XCTAssertEqual(nav.state, .idle)
  }

  func testOffRouteAsksForANewRoute() async {
    let (nav, location, spoken) = makeController(heard: "take me to mcdonald's")
    var rerouted = 0
    nav.reroute = { candidate, _ in
      rerouted += 1
      return candidate
    }
    nav.buttonPressed()
    await pause()
    nav.spoke(spoken().last!)
    await pause(0.2)
    // 40 m to the side of the route for 12 seconds.
    for i in 0...12 { location.onFix?(LocationFix(point: at(40, 30), time: 100 + Double(i))) }
    await pause()
    XCTAssertTrue(spoken().contains("Rerouting."))
    XCTAssertEqual(rerouted, 1)
    XCTAssertEqual(nav.state, .guiding)
  }
}
