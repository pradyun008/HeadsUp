import Foundation

/// A point on the ground. Plain numbers, so the navigation maths needs no MapKit and can be unit-tested.
struct GeoPoint: Equatable, Sendable {
  var lat: Double
  var lon: Double
}

/// Small geographic helpers. Distances are metres, bearings are degrees clockwise from north.
enum Geo {
  static let earthRadius = 6_371_000.0
  static let feetPerMetre = 3.28084

  static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
    let (dx, dy) = offset(from: a, to: b)
    return (dx * dx + dy * dy).squareRoot()
  }

  /// East and north offset in metres from `a` to `b`. A flat-earth approximation,
  /// accurate to centimetres over the few hundred metres a walking leg covers.
  static func offset(from a: GeoPoint, to b: GeoPoint) -> (east: Double, north: Double) {
    let north = (b.lat - a.lat) * .pi / 180 * earthRadius
    let east = (b.lon - a.lon) * .pi / 180 * earthRadius * cos(a.lat * .pi / 180)
    return (east, north)
  }

  /// The point `east` and `north` metres away from `a`.
  static func point(from a: GeoPoint, east: Double, north: Double) -> GeoPoint {
    GeoPoint(
      lat: a.lat + north / earthRadius * 180 / .pi,
      lon: a.lon + east / (earthRadius * cos(a.lat * .pi / 180)) * 180 / .pi)
  }

  /// Compass bearing from `a` to `b`, 0..<360.
  static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
    let (east, north) = offset(from: a, to: b)
    let degrees = atan2(east, north) * 180 / .pi
    return degrees < 0 ? degrees + 360 : degrees
  }

  /// Signed turn from one bearing to another, -180...180. Positive is clockwise (a right turn).
  static func turn(from: Double, to: Double) -> Double {
    var d = (to - from).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
  }

  /// Distance for speech, in feet: nearest 10 below 100 ft, nearest 50 above.
  static func spokenFeet(metres: Double) -> Int {
    let feet = max(0, metres * feetPerMetre)
    let step = feet < 100 ? 10.0 : 50.0
    return Int((feet / step).rounded() * step)
  }

  /// Clock direction (1...12) of `bearing` for someone facing `heading`. 12 is straight ahead.
  static func clock(heading: Double, bearing: Double) -> Int {
    var relative = (bearing - heading).truncatingRemainder(dividingBy: 360)
    if relative < 0 { relative += 360 }
    let hour = Int((relative / 30).rounded()) % 12
    return hour == 0 ? 12 : hour
  }
}

/// The route line, with distance measured along it from the start.
struct RoutePath: Sendable {
  let points: [GeoPoint]
  /// `cumulative[i]` is the distance along the line from the start to `points[i]`.
  let cumulative: [Double]

  init(_ points: [GeoPoint]) {
    // Drop repeated points, which have no direction.
    var kept: [GeoPoint] = []
    for p in points where kept.last.map({ Geo.distance($0, p) > 0.01 }) ?? true { kept.append(p) }
    self.points = kept
    var total = 0.0
    var sums: [Double] = kept.isEmpty ? [] : [0]
    for i in kept.indices.dropFirst() {
      total += Geo.distance(kept[i - 1], kept[i])
      sums.append(total)
    }
    cumulative = sums
  }

  var length: Double { cumulative.last ?? 0 }

  struct Snap: Equatable, Sendable {
    /// Distance along the route of the nearest point on the line.
    var along: Double
    /// How far the position is from the line.
    var offset: Double
  }

  /// The nearest point on the line to `p`.
  ///
  /// `near` limits the search to the stretch from 30 m behind to 120 m ahead of a known position,
  /// so a route that doubles back or crosses itself does not jump to the wrong leg.
  func snap(_ p: GeoPoint, near: Double? = nil) -> Snap? {
    guard points.count >= 2 else { return nil }
    var best: Snap?
    for i in 0..<(points.count - 1) {
      if let near, cumulative[i + 1] < near - 30 || cumulative[i] > near + 120 { continue }
      let (sx, sy) = Geo.offset(from: points[i], to: points[i + 1])
      let (px, py) = Geo.offset(from: points[i], to: p)
      let lengthSquared = sx * sx + sy * sy
      let t = min(1, max(0, (px * sx + py * sy) / lengthSquared))
      let dx = px - t * sx, dy = py - t * sy
      let offset = (dx * dx + dy * dy).squareRoot()
      if best == nil || offset < best!.offset {
        best = Snap(along: cumulative[i] + t * lengthSquared.squareRoot(), offset: offset)
      }
    }
    return best
  }

  /// The point at a distance along the line (clamped to its ends).
  func point(at along: Double) -> GeoPoint {
    guard let first = points.first, let last = points.last else { return GeoPoint(lat: 0, lon: 0) }
    if along <= 0 { return first }
    if along >= length { return last }
    let i = cumulative.lastIndex { $0 <= along } ?? 0
    let t = (along - cumulative[i]) / (cumulative[i + 1] - cumulative[i])
    let (east, north) = Geo.offset(from: points[i], to: points[i + 1])
    return Geo.point(from: points[i], east: east * t, north: north * t)
  }

  /// Direction of the line between two distances along it.
  func bearing(from: Double, to: Double) -> Double {
    Geo.bearing(point(at: from), point(at: to))
  }

  /// The turn at a point on the route: the direction over the `reach` metres after it
  /// compared with the `reach` metres before it. Positive is a right turn.
  ///
  /// Looking a few metres each way, not at one vertex, means a corner drawn as several
  /// short segments still reads as one turn.
  func turn(at along: Double, reach: Double = 12) -> Double {
    let before = bearing(from: max(0, along - reach), to: along)
    let after = bearing(from: along, to: min(length, along + reach))
    return Geo.turn(from: before, to: after)
  }
}
