import Foundation

/// What the laptop server found for one route, from CoStar's data layers:
/// - Vexcel aerial imagery: whether a marked crosswalk is visible at each turn.
/// - Matterport: a short description of the destination building, when it has a model.
///
/// It is fetched ONCE when guidance starts and is never part of the hazard loop. Navigation
/// works the same without it. An aerial image shows paint from a past flight; it says nothing
/// about traffic or signals, and "no detection" never means "no crosswalk".
struct RouteIntel: Codable, Sendable, Equatable {
  struct Turn: Codable, Sendable, Equatable {
    /// Index of the turn in the engine's list.
    var id: Int
    /// "ok", "empty", "outside_box", "forbidden", "rate_limited", "timeout" or "error".
    var status: String
    var crosswalk: Bool
    /// Detection boxes as [x, y, width, height], each 0–1 of the image, origin top-left.
    var boxes: [[Double]] = []
    /// Server path of the aerial image, if one was saved.
    var tile: String?
    /// The aerial image itself (JPEG), kept so the debug screen works offline and in replay.
    var image: Data?
  }
  struct Arrival: Codable, Sendable, Equatable {
    var blurb: String
  }
  var maneuvers: [Turn] = []
  var arrival: Arrival?

  /// One line for the debug screen.
  var summary: String {
    let checked = maneuvers.filter { $0.status == "ok" || $0.status == "empty" }.count
    let found = maneuvers.filter(\.crosswalk).count
    return "\(checked) of \(maneuvers.count) turns checked · \(found) with a marked crosswalk"
  }
}

enum RouteIntelClient {
  static let defaultsKey = "intelServerURL"

  /// The laptop server's address from Settings ("http://172.20.10.2:8000"). Nil means intel is off.
  static var baseURL: URL? {
    let text = (UserDefaults.standard.string(forKey: defaultsKey) ?? "").trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return URL(string: text.contains("://") ? text : "http://" + text)
  }

  /// Asks the server about a route's turns. Returns nil on any failure: the caller then simply
  /// navigates without intel. Never throws and never speaks.
  static func fetch(
    turns: [(id: Int, point: GeoPoint)], destinationName: String, destination: GeoPoint?,
    base: URL, session: URLSession = .shared, timeout: TimeInterval = 8
  ) async -> RouteIntel? {
    var body: [String: Any] = ["maneuvers": turns.map { ["id": $0.id, "lat": $0.point.lat, "lon": $0.point.lon] }]
    if let destination {
      body["destination"] = ["name": destinationName, "lat": destination.lat, "lon": destination.lon]
    }
    var request = URLRequest(url: base.appendingPathComponent("route-intel"), timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    guard
      let (data, response) = try? await session.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      var intel = decode(data)
    else { return nil }

    // The images are only for the debug screen, so each is best-effort.
    for index in intel.maneuvers.indices {
      guard let tile = intel.maneuvers[index].tile else { continue }
      let imageRequest = URLRequest(url: base.appendingPathComponent(tile), timeoutInterval: 5)
      if let (image, reply) = try? await session.data(for: imageRequest), (reply as? HTTPURLResponse)?.statusCode == 200 {
        intel.maneuvers[index].image = image
      }
    }
    return intel
  }

  /// Reads the server's JSON. Nil for anything malformed.
  static func decode(_ data: Data) -> RouteIntel? {
    try? JSONDecoder().decode(RouteIntel.self, from: data)
  }
}
