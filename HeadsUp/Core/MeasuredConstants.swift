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
///  - A held tau keeps counting down as if the object kept its speed (see `maxPause`).
///  - Real approach never makes a box jump in size from one frame to the next (see `jumpGate`).
enum MeasuredConstants {
  // MARK: - Camera

  /// Focal length of the glasses video stream, in FRAME HEIGHTS (the same units as box
  /// `top`/`bottom`, where 0 is the top of the frame and 1 the bottom).
  /// Meaning: an object 1 m tall standing 1 m from the camera has a box this many frame heights tall.
  ///
  /// STATUS: MEASURED (2026-11-14, tape test on the glasses stream at 360×640, with the Debug
  /// tab's "Focal length test"). One person, 6 ft 0 in (1.83 m):
  ///
  ///     3 m   0.625
  ///     5 m   0.637
  ///     7 m   0.648
  ///
  /// Mean 0.637, rounded to 0.64. The three readings span about 4%.
  /// A second person (5 ft 8 in) read 0.594 / 0.626 / 0.641, but the height entered on the test
  /// screen for that run is uncertain, so those readings are not used.
  /// Known pattern: the reading rises with distance (boxes are slightly tight on a near, large
  /// person). Using one value therefore reads near objects a little too far, which errs toward
  /// "moving" (toward warning).
  /// Re-measure if the stream resolution changes.
  ///
  /// A value saved on the phone by the "Focal length test" screen overrides this one, from the
  /// next time the app is opened.
  static let focalLength: Double = {
    let saved = UserDefaults.standard.double(forKey: focalLengthKey)
    return saved > 0 ? saved : builtInFocalLength
  }()
  static let builtInFocalLength = 0.64
  static let focalLengthKey = "measuredFocalLength"

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

  /// Walking yes/no comes from the phone's shake (see `StepDetector`), not Apple's activity label,
  /// which took ~10 s to switch in Run A (2026-11-15).
  /// Root-mean-square acceleration (gravity removed), in g, over `stepWindow`:
  /// above `stepWobbleStart` → walking; back to stationary only below `stepWobbleStop`.
  /// The gap between the two stops the label flipping when the shake hovers near one line.
  ///
  /// STATUS: MEASURED (2026-11-15, phone held in hand while filming, Debug tab "Step wobble"):
  ///     standing still   0.005–0.009 g
  ///     walking          up to 0.025 g (the lowest walking value was not noted)
  /// The first guess (0.05) was far too high: the phone held steady in a hand shakes much less
  /// than one in a pocket. Re-measure if the phone is carried differently.
  static let stepWobbleStart = 0.015
  static let stepWobbleStop = 0.011

  /// How many seconds of shake the step detector averages. Shorter reacts faster but flickers
  /// between steps; it should cover about 3 steps.
  ///
  /// STATUS: GUESS (1.5 s). The walking/stationary switch takes about this long both ways.
  static let stepWindow = 1.5

  /// An on-course object only switches to "walking into" (no alert) after this many frames in a
  /// row below the cutoff. It switches back to "moving" immediately. Reduces flicker without
  /// delaying real alerts.
  ///
  /// STATUS: GUESS (3 frames is 0.2 s at 15 fps).
  /// TEST: watch the debug label on the "teammate walks at you" recording for flicker.
  static let framesToSuppress = 3

  // MARK: - Suspicious jumps (SizeFilter + candidate history in Tracker)

  /// Expected frame-to-frame jitter of the detector's box size, as a fraction of the size.
  ///
  /// STATUS: GUESS (4%).
  /// TEST: point the camera at a teammate standing still at 3–5 m, record 10 s, and look at how
  /// much "box h" wobbles from frame to frame. Set this to about that wobble ÷ box h.
  static let sizeJitter = 0.04

  /// How much the box's growth rate may change by itself (speeding up, braking), relative to the
  /// box. Higher = trusts the trend less = flags less.
  ///
  /// STATUS: GUESS (0.5, from synthetic tests: a walker, a runner and an accelerating bike all stay
  /// under 1 on the "surprise" scale; a one-frame 30% jump scores about 4).
  /// TEST: replay a clip of a bike speeding up toward the camera; no sighting should be flagged.
  static let sizeRateNoise = 0.5

  /// A box more than this many standard deviations from the filter's prediction is "suspicious":
  /// left out of the tau fit and put into a candidate history instead.
  ///
  /// STATUS: GUESS (3). At 4% jitter, a one-frame jump of about 20% or more is flagged.
  /// TEST: replay clips of two people crossing; the merge frames should show "jump?" on the debug
  /// screen, normal walking frames should not.
  static let jumpGate = 3.0

  /// A jump that lasts this many frames in a row is accepted as real: the candidate history
  /// replaces the old one. Until then the old judgment is held (tau counting down).
  ///
  /// STATUS: GUESS (3 frames = 0.2 s at 15 fps).
  static let jumpAcceptFrames = 3

  // MARK: - Paused judgment

  /// A held judgment (head turning, track briefly lost, jump candidate, history rebuilding) counts
  /// its tau down while held. After this many seconds of pause it is DROPPED to "no judgment" and
  /// must be rebuilt from fresh sightings: no warnings about something we can't currently judge.
  ///
  /// STATUS: GUESS (2 s, chosen 2026-11-14).
  static let maxPause = 2.0
}
