import CoreLocation
import Foundation

/// Where position reports come from: live GPS, or a recorded walk replayed for tests and demos.
@MainActor
protocol LocationProvider: AnyObject {
  var onFix: ((LocationFix) -> Void)? { get set }
  /// A short message when positions cannot be delivered ("Location permission needed"), or nil when fine.
  var onProblem: ((String?) -> Void)? { get set }
  func start()
  func stop()
}

/// Live position from the phone's GPS, with compass heading when the phone has one.
///
/// The compass describes the way the PHONE points, not the wearer's head or body. In a pocket it
/// is often wrong, so the engine uses it only for the first cue and only when it reports good accuracy.
@MainActor
final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
  var onFix: ((LocationFix) -> Void)?
  var onProblem: ((String?) -> Void)?
  private let manager = CLLocationManager()
  private var heading: CLHeading?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    manager.activityType = .fitness
    manager.distanceFilter = kCLDistanceFilterNone
  }

  func start() {
    switch manager.authorizationStatus {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .denied, .restricted: onProblem?("Location permission needed. Turn it on in Settings.")
    default: break
    }
    manager.startUpdatingLocation()
    manager.startUpdatingHeading()
  }

  func stop() {
    manager.stopUpdatingLocation()
    manager.stopUpdatingHeading()
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    Task { @MainActor in
      self.onProblem?(nil)
      self.onFix?(
        LocationFix(
          point: GeoPoint(lat: location.coordinate.latitude, lon: location.coordinate.longitude),
          accuracy: location.horizontalAccuracy,
          heading: self.heading?.trueHeading,
          headingAccuracy: self.heading?.headingAccuracy,
          time: location.timestamp.timeIntervalSinceReferenceDate))
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
    Task { @MainActor in self.heading = newHeading }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // iOS also reports "denied" while the permission question is still on screen, so the
    // permission message is shown only once the answer really is no.
    let status = manager.authorizationStatus
    let refused = status == .denied || status == .restricted
    Task { @MainActor in
      self.onProblem?(refused ? "Location permission needed. Turn it on in Settings." : "No GPS position yet.")
    }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor in
      if status == .denied || status == .restricted {
        self.onProblem?("Location permission needed. Turn it on in Settings.")
      }
    }
  }
}

/// Replays a recorded walk at its recorded pace (or faster), so navigation can be tested and
/// demonstrated indoors with no GPS.
@MainActor
final class GPXReplayProvider: LocationProvider {
  var onFix: ((LocationFix) -> Void)?
  var onProblem: ((String?) -> Void)?
  private let fixes: [LocationFix]
  /// 1 plays in real time, 4 plays four times faster.
  private let speed: Double
  private var task: Task<Void, Never>?

  init(fixes: [LocationFix], speed: Double = 1) {
    self.fixes = fixes
    self.speed = max(0.1, speed)
  }

  func start() {
    stop()
    guard !fixes.isEmpty else {
      onProblem?("The recorded walk is empty.")
      return
    }
    task = Task { [fixes, speed] in
      var previous = fixes[0].time
      for fix in fixes {
        let wait = max(0, fix.time - previous) / speed
        previous = fix.time
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        if Task.isCancelled { return }
        self.onFix?(fix)
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }
}

/// Reads the track points of a GPX file (the common format for recorded GPS walks).
enum GPX {
  /// Track points in file order. Times are seconds from the first point.
  /// Points with no `<time>` are spaced one second apart.
  static func parse(_ data: Data) -> [LocationFix] {
    let reader = Reader()
    let parser = XMLParser(data: data)
    parser.delegate = reader
    parser.parse()
    guard let first = reader.points.first else { return [] }
    let start = first.date
    return reader.points.enumerated().map { index, point in
      let time = (start != nil && point.date != nil) ? point.date!.timeIntervalSince(start!) : Double(index)
      return LocationFix(point: point.point, accuracy: point.accuracy ?? 5, time: time)
    }
  }

  /// Writes fixes as GPX, for saving a walk recorded by the app.
  static func write(_ fixes: [LocationFix], startingAt start: Date = Date(timeIntervalSince1970: 0)) -> String {
    let formatter = ISO8601DateFormatter()
    let base = fixes.first?.time ?? 0
    let points = fixes.map { fix in
      "<trkpt lat=\"\(fix.point.lat)\" lon=\"\(fix.point.lon)\"><time>\(formatter.string(from: start.addingTimeInterval(fix.time - base)))</time><hdop>\(fix.accuracy / 5)</hdop></trkpt>"
    }
    return "<?xml version=\"1.0\"?>\n<gpx version=\"1.1\" creator=\"HeadsUp\"><trk><trkseg>\n"
      + points.joined(separator: "\n") + "\n</trkseg></trk></gpx>\n"
  }

  private final class Reader: NSObject, XMLParserDelegate {
    struct Point {
      var point: GeoPoint
      var date: Date?
      var accuracy: Double?
    }
    var points: [Point] = []
    private var current: Point?
    private var text = ""
    private let withFraction: ISO8601DateFormatter = {
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return f
    }()
    private let plain = ISO8601DateFormatter()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
      text = ""
      if name == "trkpt", let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) {
        current = Point(point: GeoPoint(lat: lat, lon: lon))
      }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
      let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
      switch name {
      case "time": current?.date = plain.date(from: value) ?? withFraction.date(from: value)
      // GPX has no accuracy field. HDOP times about 5 m is the usual rough conversion.
      case "hdop": current?.accuracy = Double(value).map { $0 * 5 }
      case "trkpt":
        if let current { points.append(current) }
        current = nil
      default: break
      }
    }
  }
}
