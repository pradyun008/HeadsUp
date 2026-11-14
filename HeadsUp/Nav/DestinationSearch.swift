import MapKit

/// One place the wearer might mean, with the walking route to it.
struct DestinationCandidate: Sendable {
  var name: String
  /// Street the place is on, if the map knows it.
  var street: String?
  var point: GeoPoint
  var route: NavRoute
  var distanceMetres: Double
  var minutes: Int

  /// "McDonald's on Nassau Street, about 0.8 miles, 17 minutes."
  /// Miles are used only here, for the length of the whole trip. Every guidance cue is in feet.
  var spokenSummary: String {
    let place = street.map { "\(name) on \($0)" } ?? name
    let miles = distanceMetres / 1609.344
    let distance = miles < 0.1 ? "\(Geo.spokenFeet(metres: distanceMetres)) feet" : String(format: "%.1f miles", miles)
    return "\(place), about \(distance), \(max(1, minutes)) \(minutes == 1 ? "minute" : "minutes")."
  }
}

/// Finds places by name and ranks them by walking time, using Apple Maps.
/// This needs the network. It is never part of the hazard loop, which stays on-device.
enum DestinationSearch {
  /// Up to five matches near `origin`, nearest by walking time first.
  static func find(_ query: String, near origin: GeoPoint) async throws -> [DestinationCandidate] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    request.region = MKCoordinateRegion(
      center: CLLocationCoordinate2D(latitude: origin.lat, longitude: origin.lon),
      latitudinalMeters: 6000, longitudinalMeters: 6000)
    let items = try await MKLocalSearch(request: request).start().mapItems.prefix(5)

    // Straight-line distance is misleading for walking (rivers, campus walls), so each
    // candidate gets a real walking route and the list is sorted by its time.
    let candidates = await withTaskGroup(of: DestinationCandidate?.self) { group in
      for item in items {
        group.addTask { try? await route(to: item, from: origin) }
      }
      var found: [DestinationCandidate] = []
      for await candidate in group { if let candidate { found.append(candidate) } }
      return found
    }
    return candidates.sorted { $0.minutes == $1.minutes ? $0.distanceMetres < $1.distanceMetres : $0.minutes < $1.minutes }
  }

  /// A fresh route to a place already chosen. Used for rerouting.
  static func reroute(to candidate: DestinationCandidate, from origin: GeoPoint) async throws -> DestinationCandidate {
    let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: candidate.point.lat, longitude: candidate.point.lon)))
    var fresh = try await route(to: item, from: origin)
    fresh.name = candidate.name
    fresh.street = candidate.street
    fresh.route.destinationName = candidate.name
    return fresh
  }

  private static func route(to item: MKMapItem, from origin: GeoPoint) async throws -> DestinationCandidate {
    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: origin.lat, longitude: origin.lon)))
    request.destination = item
    request.transportType = .walking
    guard let route = try await MKDirections(request: request).calculate().routes.first else {
      throw MKError(.directionsNotFound)
    }
    let name = item.name ?? "the destination"
    let point = GeoPoint(lat: item.placemark.coordinate.latitude, lon: item.placemark.coordinate.longitude)
    let steps = route.steps.map { step in
      let count = step.polyline.pointCount
      var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
      step.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: count))
      return RouteStep(points: coordinates.map { GeoPoint(lat: $0.latitude, lon: $0.longitude) }, instruction: step.instructions)
    }
    return DestinationCandidate(
      name: name,
      street: item.placemark.thoroughfare.map(NavRoute.spokenStreet),
      point: point,
      route: NavRoute(steps: steps, destinationName: name, destination: point),
      distanceMetres: route.distance,
      minutes: Int((route.expectedTravelTime / 60).rounded()))
  }
}

/// One step of a map route: the line walked, then the instruction carried out at its end.
struct RouteStep: Sendable {
  var points: [GeoPoint]
  var instruction: String
}

extension NavRoute {
  /// Builds a route from map steps.
  ///
  /// In Apple Maps walking routes, each step's instruction happens at the END of that step's
  /// line (checked against real Princeton routes on 2026-11-14). So the junctions are the points
  /// where one step's line ends and the next begins. The instruction text is used only for the
  /// street name after "onto"; left and right come from the shape of the line.
  init(steps: [RouteStep], destinationName: String, destination: GeoPoint?) {
    var points: [GeoPoint] = []
    var junctions: [Junction] = []
    for (index, step) in steps.enumerated() {
      points.append(contentsOf: step.points)
      guard index < steps.count - 1, !step.points.isEmpty else { continue }
      var street: String?
      if let range = step.instruction.range(of: " onto ") {
        let name = step.instruction[range.upperBound...].trimmingCharacters(in: .whitespaces)
        // "onto the path" and "onto the road" are not names worth saying.
        if !name.isEmpty, !name.lowercased().hasPrefix("the ") { street = Self.spokenStreet(name) }
      }
      junctions.append(Junction(along: RoutePath(points).length, street: street))
    }
    self.init(path: RoutePath(points), junctions: junctions, startStreet: nil, destinationName: destinationName, destination: destination)
  }

  /// Expands map abbreviations so the voice says "Road", not "R d".
  static func spokenStreet(_ name: String) -> String {
    let endings = ["St": "Street", "Rd": "Road", "Ave": "Avenue", "Ln": "Lane", "Dr": "Drive", "Blvd": "Boulevard", "Pl": "Place", "Ct": "Court", "Hwy": "Highway", "Pkwy": "Parkway"]
    var words = name.split(separator: " ").map(String.init)
    if let last = words.last, let full = endings[last.trimmingCharacters(in: .punctuationCharacters)] {
      words[words.count - 1] = full
    }
    return words.joined(separator: " ")
  }
}
