import Foundation

/// A scripted scene: objects moving in metres relative to a wearer, projected through a
/// simple pinhole camera into normalized detections. Used by the scripted frame source
/// (no camera or YOLO needed) and by unit tests.
///
/// World axes, relative to the camera: x = metres to the right, z = metres ahead.
struct Scenario: Sendable {
  struct Actor: Sendable {
    var objectClass: ObjectClass
    /// Position at `startTime`, metres. x: right of camera, z: ahead of camera.
    var x: Double
    var z: Double
    /// Velocity RELATIVE to the wearer, metres per second.
    var vx: Double
    var vz: Double
    /// Physical size, metres.
    var width: Double
    var height: Double
    var startTime: Double
    var endTime: Double
  }

  /// A head turn: the whole image content shifts sideways between `start` and `end`.
  struct HeadTurn: Sendable {
    var start: Double
    var end: Double
    /// Total content shift in normalized x units. Positive = content moves right (head turns left).
    var shift: Double
  }

  var name: String
  var duration: Double
  var actors: [Actor]
  /// Should sum to zero shift so the scene loops cleanly.
  var headTurns: [HeadTurn] = []

  /// Where the image content sits, relative to looking straight ahead, at `time`.
  func contentOffset(at time: Double) -> Double {
    let t = time.truncatingRemainder(dividingBy: duration)
    return headTurns.reduce(0) { total, turn in
      let progress = min(1, max(0, (t - turn.start) / (turn.end - turn.start)))
      return total + turn.shift * progress
    }
  }

  /// Focal length in normalized x units: 1 / tan(half horizontal field of view).
  /// 35° half-FOV is a rough match for a wide portrait camera.
  static let focal = 1.0 / tan(35.0 * .pi / 180)
  /// Frame is 9:16 portrait, so its height spans 2 × 16/9 x-units.
  static let heightInXUnits = 2.0 * 16.0 / 9.0
  /// Closest distance still drawn; nearer than this the object has reached the wearer.
  static let nearPlane = 0.4

  /// Detections at `time` seconds into the scenario (wraps at `duration`).
  func detections(at time: Double) -> [Detection] {
    let t = time.truncatingRemainder(dividingBy: duration)
    let offset = contentOffset(at: time)
    return actors.compactMap { actor in
      guard t >= actor.startTime, t <= actor.endTime else { return nil }
      let dt = t - actor.startTime
      return Self.project(actor, x: actor.x + actor.vx * dt, z: actor.z + actor.vz * dt, offset: offset)
    }
  }

  static func project(_ actor: Actor, x: Double, z: Double, offset: Double = 0) -> Detection? {
    guard z > nearPlane else { return nil }
    let cx = focal * x / z + offset
    let halfW = focal * actor.width / (2 * z)
    let h = focal * actor.height / z / heightInXUnits
    // Feet a little below the horizon (camera at head height looking level).
    let bottom = 0.5 + focal * 1.5 / z / heightInXUnits
    let left = cx - halfW, right = cx + halfW
    // Fully out of frame: nothing to detect.
    guard right > -1, left < 1 else { return nil }
    return Detection(
      objectClass: actor.objectClass, confidence: 0.9,
      left: max(-1, left), right: min(1, right),
      top: max(0, bottom - h), bottom: min(1, bottom))
  }
}

extension Scenario {
  private static func person(x: Double, z: Double, vx: Double = 0, vz: Double, from: Double, to: Double) -> Actor {
    Actor(objectClass: .person, x: x, z: z, vx: vx, vz: vz, width: 0.5, height: 1.7, startTime: from, endTime: to)
  }

  /// Someone walks straight at the wearer (closing at 1.4 m/s from 12 m).
  static let walksToward = Scenario(
    name: "Walks toward", duration: 10,
    actors: [person(x: 0, z: 12, vz: -1.4, from: 0.5, to: 9)])

  /// Someone walks past, 1 m to the wearer's camera-right.
  static let walksPast = Scenario(
    name: "Walks past", duration: 10,
    actors: [person(x: 1.0, z: 12, vz: -1.4, from: 0.5, to: 9)])

  /// The hackathon demo: one person passes on the camera-left, then one comes straight on.
  static let demo = Scenario(
    name: "Past, then toward", duration: 20,
    actors: [
      person(x: -1.0, z: 12, vz: -1.4, from: 0.5, to: 9),
      person(x: 0.05, z: 12, vz: -1.4, from: 10.5, to: 19),
    ])

  /// A bike closing fast from ahead-left that ends up on the wearer.
  static let bikeFromLeft = Scenario(
    name: "Bike from left", duration: 8,
    actors: [
      Actor(objectClass: .bicycle, x: -3, z: 20, vx: 0.75, vz: -5, width: 0.6, height: 1.7, startTime: 0.5, endTime: 4.5)
    ])

  /// Someone crosses far ahead without getting closer.
  static let crossesFar = Scenario(
    name: "Crosses far away", duration: 10,
    actors: [person(x: -6, z: 10, vx: 1.4, vz: 0, from: 0.5, to: 9)])

  /// Someone walks away from the wearer.
  static let walksAway = Scenario(
    name: "Walks away", duration: 10,
    actors: [person(x: 0, z: 3, vz: 1.4, from: 0.5, to: 9)])

  /// A quick glance to the side and back (0.3 s each way) starting at `time`.
  static func glance(at time: Double, shift: Double = 0.25) -> [HeadTurn] {
    [HeadTurn(start: time, end: time + 0.3, shift: shift), HeadTurn(start: time + 0.8, end: time + 1.1, shift: -shift)]
  }

  /// Someone walks straight at the wearer while the wearer glances aside and back.
  static let towardWithGlance = Scenario(
    name: "Toward, with a glance aside", duration: 10,
    actors: [person(x: 0, z: 12, vz: -1.4, from: 0.5, to: 9)], headTurns: glance(at: 5.5))

  static let all: [Scenario] = [
    .demo, .walksToward, .walksPast, .bikeFromLeft, .crossesFar, .walksAway, .towardWithGlance,
  ]
}
