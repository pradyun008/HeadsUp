import Foundation

/// A route plus the positions of one walk along it, saved so navigation can be replayed with
/// no GPS and no network (the judging-table demo, and repeatable tests).
///
/// Saved walks live in the app's Documents folder as `<name>.walk.json`, next to recorded video.
/// They are never part of the repository.
struct SavedWalk: Codable, Sendable, Equatable {
  struct Point: Codable, Sendable, Equatable {
    var lat: Double
    var lon: Double
  }
  struct Junction: Codable, Sendable, Equatable {
    var along: Double
    var street: String?
    var crosswalk: Bool
  }
  struct Fix: Codable, Sendable, Equatable {
    var lat: Double
    var lon: Double
    var accuracy: Double
    var time: Double
    var heading: Double?
    var headingAccuracy: Double?
  }

  var name: String
  var destinationName: String
  var destination: Point?
  var startStreet: String?
  var route: [Point]
  var junctions: [Junction]
  var fixes: [Fix]
  /// The aerial-image findings for this route, if the walk was saved with them. Lets the replay
  /// demo show crosswalk images and speak the arrival blurb with no server.
  var intel: RouteIntel?

  init(name: String, route: NavRoute, fixes: [LocationFix]) {
    self.name = name
    destinationName = route.destinationName
    destination = route.destination.map { Point(lat: $0.lat, lon: $0.lon) }
    startStreet = route.startStreet
    self.route = route.path.points.map { Point(lat: $0.lat, lon: $0.lon) }
    junctions = route.junctions.map { Junction(along: $0.along, street: $0.street, crosswalk: $0.crosswalk) }
    let start = fixes.first?.time ?? 0
    self.fixes = fixes.map {
      Fix(lat: $0.point.lat, lon: $0.point.lon, accuracy: $0.accuracy, time: $0.time - start,
          heading: $0.heading, headingAccuracy: $0.headingAccuracy)
    }
  }

  var navRoute: NavRoute {
    NavRoute(
      path: RoutePath(route.map { GeoPoint(lat: $0.lat, lon: $0.lon) }),
      junctions: junctions.map { NavRoute.Junction(along: $0.along, street: $0.street, crosswalk: $0.crosswalk) },
      startStreet: startStreet,
      destinationName: destinationName,
      destination: destination.map { GeoPoint(lat: $0.lat, lon: $0.lon) })
  }

  var locationFixes: [LocationFix] {
    fixes.map {
      LocationFix(point: GeoPoint(lat: $0.lat, lon: $0.lon), accuracy: $0.accuracy,
                  heading: $0.heading, headingAccuracy: $0.headingAccuracy, time: $0.time)
    }
  }

  /// Length of the walk in seconds.
  var duration: Double { fixes.last?.time ?? 0 }

  // MARK: Making walks

  /// A walk along a route at a steady pace, one position per second, for when nobody has
  /// physically walked it. `wobble` moves each position sideways by up to that many metres,
  /// in a slow drift like real GPS beside buildings (repeatable: no randomness).
  static func simulated(name: String, route: NavRoute, speed: Double = 1.35, wobble: Double = 3) -> SavedWalk {
    let path = route.path
    var fixes: [LocationFix] = []
    var along = 0.0
    var time = 0.0
    while true {
      let clamped = min(along, path.length)
      let bearing = path.bearing(from: max(0, clamped - 1), to: min(path.length, clamped + 1)) * .pi / 180
      let side = wobble * sin(time / 9) * cos(time / 23)
      let point = Geo.point(from: path.point(at: clamped), east: side * cos(bearing), north: -side * sin(bearing))
      fixes.append(LocationFix(point: point, accuracy: 5 + abs(side), time: time))
      if along >= path.length { break }
      along += speed
      time += 1
    }
    return SavedWalk(name: name, route: route, fixes: fixes)
  }

  /// A made-up walk around one block that ships with the app, so replay works before any real
  /// walk has been saved. The coordinates are not a real route.
  static let builtIn: SavedWalk = {
    let origin = GeoPoint(lat: 40.0, lon: -75.0)
    func at(_ east: Double, _ north: Double) -> GeoPoint { Geo.point(from: origin, east: east, north: north) }
    let route = NavRoute(
      path: RoutePath([at(0, 0), at(0, 110), at(-90, 110), at(-90, 190), at(-20, 190)]),
      junctions: [
        .init(along: 110, street: "Maple Street", crosswalk: true),
        .init(along: 200, street: "Oak Avenue"),
        .init(along: 280),
      ],
      startStreet: "Main Street",
      destinationName: "the library",
      destination: at(-20, 198))
    return simulated(name: "Built-in block", route: route)
  }()

  // MARK: Files

  static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

  /// Saves to Documents and returns the file. The name is made safe for a file name.
  @discardableResult
  func save(in folder: URL = SavedWalk.folder) throws -> URL {
    let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " ? $0 : "-" }
    let url = folder.appendingPathComponent(String(safe).trimmingCharacters(in: .whitespaces) + ".walk.json")
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
    return url
  }

  /// Every saved walk in Documents, newest first, followed by the built-in one.
  static func all(in folder: URL = SavedWalk.folder) -> [SavedWalk] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let saved = files
      .filter { $0.lastPathComponent.hasSuffix(".walk.json") }
      .sorted {
        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return a > b
      }
      .compactMap { try? JSONDecoder().decode(SavedWalk.self, from: Data(contentsOf: $0)) }
    return saved + [builtIn]
  }
}
