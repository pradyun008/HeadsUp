import Foundation

/// The crossing scan: on request, the app says "Look left", waits, says "Look right", waits,
/// then reports only what the camera saw in each direction ("car, left" or "nothing seen").
///
/// It NEVER gives a verdict about crossing, never says anything is safe or clear, never reads
/// walk signals, and does not know where streets or crosswalks are. "Nothing seen" means only
/// that the camera saw no vehicle or bike during the scan.
enum ScanPhase: String, Sendable {
  /// The wearer was asked to look left. Sightings in this phase are reported as "left".
  case left
  case right
}

struct CrossingScanConfig: Sendable, Equatable, Codable {
  /// How long each direction is watched after its prompt.
  var lookSeconds = 2.0
  /// Time allowed for a prompt to be spoken before its watch window is counted.
  var promptSeconds = 0.8
  /// A class must be seen in at least this many frames of a phase to be reported,
  /// so a single false detection is not announced.
  var minFrames = 3
  /// Shortest gap between automatic scans.
  var autoCooldown = 20.0
}

/// Collects what was seen during one scan and words the report.
struct CrossingScanLog: Sendable {
  var minFrames = 3
  /// Frames in which each spoken class ("car", "bike") was seen, per phase.
  private var frames: [ScanPhase: [String: Int]] = [:]

  init(minFrames: Int = 3) { self.minFrames = minFrames }

  /// Call once per processed frame while a phase is active.
  ///
  /// Only vehicles and bikes are counted. People are left out: on a sidewalk they are
  /// everywhere, and the normal collision-course warnings already cover them.
  /// Head turns scramble track IDs, so this counts frames per class, not per track.
  mutating func observe(_ tracks: [Track], phase: ScanPhase) {
    let seen = Set(tracks.filter { !$0.isCoasting && $0.objectClass != .person }.map(\.objectClass.spokenName))
    for name in seen { frames[phase, default: [:]][name, default: 0] += 1 }
  }

  /// What was seen, as (class, side) pairs: left before right, cars before bikes.
  var sightings: [(name: String, phase: ScanPhase)] {
    var out: [(String, ScanPhase)] = []
    for phase in [ScanPhase.left, .right] {
      for name in ["car", "bike"] where (frames[phase]?[name] ?? 0) >= minFrames {
        out.append((name, phase))
      }
    }
    return out
  }

  /// "car, left. bike, right" or "nothing seen". A report of what was seen, never advice.
  var report: String {
    let items = sightings
    guard !items.isEmpty else { return "nothing seen" }
    return items.map { "\($0.name), \($0.phase.rawValue)" }.joined(separator: ". ")
  }
}

/// Recognizes the spoken trigger phrase "HeadsUp, crossing" in a speech transcript.
enum CrossingScanPhrase {
  static func matches(_ transcript: String) -> Bool {
    // Keep letters only, so "Heads up, crossing." and "headsup crossing" look the same.
    let letters = transcript.lowercased().filter { $0.isLetter }
    for name in ["headsup", "headup", "headzup"] {
      if let range = letters.range(of: name), letters[range.upperBound...].contains("crossing") { return true }
    }
    return false
  }
}

/// Decides when "the wearer has stopped walking for a few seconds" for the automatic trigger.
/// Fires once per stop, only after walking was seen, and re-arms when walking resumes.
struct StopWalkingLogic: Sendable {
  var stopSeconds = 3.0
  private var armed = false
  private var stoppedSince: Double?

  /// - Parameter walking: true while walking or running, false while still.
  /// - Returns: true exactly once, when the wearer has been still for `stopSeconds` after walking.
  mutating func update(time: Double, walking: Bool) -> Bool {
    if walking {
      armed = true
      stoppedSince = nil
      return false
    }
    guard armed else { return false }
    if stoppedSince == nil { stoppedSince = time }
    if let since = stoppedSince, time - since >= stopSeconds {
      armed = false
      stoppedSince = nil
      return true
    }
    return false
  }

  mutating func reset() {
    armed = false
    stoppedSince = nil
  }
}
