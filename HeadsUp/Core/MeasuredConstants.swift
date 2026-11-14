import Foundation

/// Every number and assumption the "Is it moving?" check is built on, in one place, so we know
/// exactly what we're guessing and can test each one later.
///
/// Each entry says its STATUS:
///   PLACEHOLDER = not measured yet; the app runs but results aren't trustworthy until it is.
///   GUESS       = a reasonable starting value; test it and update the number here.
///   MEASURED    = checked on our own glasses/test (write the date and how).
///
/// Changing a value here needs a rebuild of the app. Thresholds Roman's code already exposes in
/// Settings (tau levels, corridor width, smoothing) are guesses too; they live in `RiskConfig`.
///
/// Assumptions in the logic (not numbers), also to be tested:
///  - The head faces the walking direction. Distance is forward distance along where the camera
///    points, and the wearer's walking speed is subtracted in that same direction.
///  - Objects are upright, so box HEIGHT stays about the same from any viewing angle.
///  - Each class has one typical height (kids, people sitting and odd vehicles break this).
///  - No activity reading yet (startup) means stationary: subtract nothing, so no misses.
///  - A cut-off box's distance is replaced by the object's last reliable distance; an object that
///    never had a reliable distance is never suppressed as "walking into".
enum MeasuredConstants {
  // MARK: - Camera

  /// Focal length of the glasses video stream, in FRAME HEIGHTS (the same units as box
  /// `top`/`bottom`, where 0 is the top of the frame and 1 the bottom).
  /// Meaning: an object 1 m tall standing 1 m from the camera has a box this many frame heights tall.
  ///
  /// STATUS: PLACEHOLDER.
  /// TEST (tape test, at the demo stream resolution): stand a person of known height at 3 m, 5 m and
  /// 7 m (whole body in frame, near the centre), read "box h" on the debug screen, and average
  /// f = box h × distance ÷ person's height. Re-measure if the stream resolution changes.
  static let focalLength = 0.6

  // MARK: - Object sizes

  /// Typical real HEIGHT in metres for each kept class, used for distance.
  ///
  /// STATUS: GUESS (rough real-world averages; trucks vary most, 1.9 m pickup to 4 m semi).
  /// TEST: with f measured, stand each kind of object at a taped distance and compare the app's Z
  /// with the tape. If Z is consistently off for a class, adjust its height here.
  static func typicalHeight(of objectClass: ObjectClass) -> Double {
    switch objectClass {
    case .person: return 1.7
    case .bicycle: return 1.05
    case .motorcycle: return 1.15
    case .car: return 1.5
    case .bus: return 3.1
    case .truck: return 2.5
    }
  }

  // MARK: - Distance

  /// A box this close (in frame heights) to the top or bottom edge counts as cut off, so its
  /// distance is marked unreliable (the box is too short, so Z reads too far).
  ///
  /// STATUS: GUESS.
  /// TEST: walk toward the camera until your head or feet leave the frame and check when the
  /// debug label starts showing "?".
  static let cutOffMargin = 0.01

  // MARK: - Is it moving?

  /// While the wearer walks, an on-course object counts as moving toward them only if its own
  /// speed (closing speed − wearer speed) is above this, in metres per second.
  /// Below it, the object is "walking into": the wearer is approaching something mostly still.
  ///
  /// STATUS: GUESS (1.0 m/s chosen as a middle between 0.7, which flickers on oncoming walkers,
  /// and 1.5, which only catches runners, bikes and cars).
  /// TEST: record (1) walking toward a standing teammate, (2) a teammate walking at you, (3) a
  /// teammate jogging at you. Read "own" on the debug screen for each and pick a value that
  /// separates (1) from the ones you want to warn about.
  static let movingCutoff = 1.0

  /// Wearer speed in m/s to use when the phone says "walking" but has no pace reading yet
  /// (just started walking, or the app just started). Kept on the low side on purpose:
  /// overestimating the wearer's speed subtracts too much and can hide a real mover.
  ///
  /// STATUS: GUESS (typical walking is about 1.2–1.4 m/s).
  /// TEST: compare with the pace reading the debug screen shows once it arrives.
  static let defaultWalkingSpeed = 1.0

  /// An on-course object only switches to "walking into" (no alert) after this many frames in a
  /// row below the cutoff. It switches back to "moving" immediately. Reduces flicker without
  /// delaying real alerts.
  ///
  /// STATUS: GUESS (3 frames is 0.2 s at 15 fps).
  /// TEST: watch the debug label on the "teammate walks at you" recording for flicker.
  static let framesToSuppress = 3
}
