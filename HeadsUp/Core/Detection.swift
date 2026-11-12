import Foundation

/// The COCO classes HeadsUp keeps. COCO has no scooter class; scooter riders show up as person.
enum ObjectClass: String, CaseIterable, Sendable {
  case person, bicycle, motorcycle, car, bus, truck

  /// Word used in speech: "bike" for bicycle/motorcycle, "car" for car/bus/truck.
  var spokenName: String {
    switch self {
    case .person: return "person"
    case .bicycle, .motorcycle: return "bike"
    case .car, .bus, .truck: return "car"
    }
  }
}

/// One detected object in one frame.
///
/// Horizontal coordinates are normalized and CAMERA-RELATIVE: −1 is the left edge of the
/// frame, +1 the right edge, 0 the centre. The camera follows the head, not the body.
/// Vertical coordinates run 0 (top) to 1 (bottom).
struct Detection: Equatable, Sendable {
  var objectClass: ObjectClass
  var confidence: Float
  var left: Double
  var right: Double
  var top: Double
  var bottom: Double

  var centerX: Double { (left + right) / 2 }
  var width: Double { right - left }
  var height: Double { bottom - top }
  /// Area in normalized units (x units × y units). Only ratios over time matter.
  var area: Double { max(0, width) * max(0, height) }
}
