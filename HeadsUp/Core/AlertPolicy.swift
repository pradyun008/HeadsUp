import Foundation

struct AlertConfig: Sendable, Equatable {
  /// A higher level must hold this many consecutive frames before the output rises.
  var upFrames = 3
  /// A lower level must hold this many consecutive frames before the output falls.
  var downFrames = 5
  /// Speak when a track first reaches this level.
  var speechMinLevel = 2
  /// Never speak about the same track twice within this many seconds.
  var repeatInterval = 4.0
}

/// A short spoken report of what was seen, e.g. "bike, left".
/// It only reports. It never tells the wearer what to do or that anything is safe.
struct SpeechCue: Equatable, Sendable {
  var text: String
  /// Higher speaks first and can interrupt lower. Hazard cues use their level (2–3); status uses 0.
  var priority: Int
  var trackID: Int?
}

struct AlertState: Equatable, Sendable {
  /// 0–3. Driven by hazards on the camera-left, and by hazards ahead.
  var leftLevel = 0
  /// 0–3. Driven by hazards on the camera-right, and by hazards ahead.
  var rightLevel = 0
  /// Cues to speak this frame, highest priority first. Usually empty.
  var cues: [SpeechCue] = []
  /// Smoothed level per track, for display.
  var trackLevels: [Int: Int] = [:]
}

/// Turns per-track risk into one steady output: a left level, a right level, and speech cues.
///
/// Smoothing (hysteresis) is per track: a level has to hold for `upFrames` frames to go up and
/// `downFrames` to go down, so one noisy frame cannot make the band flicker or trigger speech.
/// A track that disappears is treated as level 0 and steps down by the same rule.
struct AlertPolicy: Sendable {
  var config = AlertConfig()

  private struct Entry {
    var level = 0
    var upRun: [Int] = []
    var downRun: [Int] = []
    var side: Side = .ahead
    var objectClass: ObjectClass
    var lastSpoken: Double?
    var spokenLevel = 0
    var spokenSide: Side?
  }
  private var entries: [Int: Entry] = [:]

  mutating func reset() { entries = [:] }

  mutating func update(risk: RiskFrame, tracks: [Track], time: Double) -> AlertState {
    var seen = Set<Int>()
    for assessment in risk.assessments {
      guard let track = tracks.first(where: { $0.id == assessment.trackID }) else { continue }
      seen.insert(track.id)
      var entry = entries[track.id] ?? Entry(objectClass: track.objectClass)
      entry.objectClass = track.objectClass
      if assessment.state == .onCourse, let side = assessment.side { entry.side = side }
      step(&entry, raw: assessment.level)
      entries[track.id] = entry
    }
    // Tracks that are gone: raw level 0 until the smoothed level has stepped down, then forget them.
    for id in entries.keys where !seen.contains(id) {
      var entry = entries[id]!
      step(&entry, raw: 0)
      entries[id] = entry.level == 0 ? nil : entry
    }

    var state = AlertState()
    for (id, entry) in entries {
      state.trackLevels[id] = entry.level
      guard entry.level > 0 else { continue }
      // LEFT drives the left channel, RIGHT the right, AHEAD both. Max per side.
      if entry.side != .right { state.leftLevel = max(state.leftLevel, entry.level) }
      if entry.side != .left { state.rightLevel = max(state.rightLevel, entry.level) }
    }

    for id in entries.keys.sorted() {
      var entry = entries[id]!
      if entry.level < config.speechMinLevel {
        entry.spokenLevel = 0  // next time it reaches the speech level counts as a new event
      } else if entry.level > entry.spokenLevel || entry.side != entry.spokenSide {
        // New event for this track (first time at the speech level, got worse, or changed side),
        // but never twice within the repeat interval.
        if entry.lastSpoken.map({ time - $0 >= config.repeatInterval }) ?? true {
          state.cues.append(
            SpeechCue(
              text: "\(entry.objectClass.spokenName), \(entry.side.rawValue)",
              priority: entry.level, trackID: id))
          entry.lastSpoken = time
          entry.spokenLevel = entry.level
          entry.spokenSide = entry.side
        }
      }
      entries[id] = entry
    }
    state.cues.sort { $0.priority > $1.priority }
    return state
  }

  private func step(_ entry: inout Entry, raw: Int) {
    if raw > entry.level {
      entry.downRun = []
      entry.upRun.append(raw)
      if entry.upRun.count >= config.upFrames {
        // Rise to the level that actually held for the whole run.
        entry.level = entry.upRun.suffix(config.upFrames).min() ?? raw
        entry.upRun = []
      }
    } else if raw < entry.level {
      entry.upRun = []
      entry.downRun.append(raw)
      if entry.downRun.count >= config.downFrames {
        entry.level = entry.downRun.suffix(config.downFrames).max() ?? raw
        entry.downRun = []
      }
    } else {
      entry.upRun = []
      entry.downRun = []
    }
  }
}

/// Decides what to say when cues compete. There is never more than one utterance waiting:
/// a newer or higher-priority cue replaces whatever was waiting, and a higher-priority cue
/// interrupts one that is being spoken.
struct SpeechQueue: Sendable {
  enum Action: Equatable {
    /// Start speaking this now. `interrupt` means stop the current utterance first.
    case speak(SpeechCue, interrupt: Bool)
    /// Held in the single waiting slot.
    case wait
    /// Discarded because something more important is already waiting.
    case drop
  }

  private(set) var current: SpeechCue?
  private(set) var pending: SpeechCue?

  mutating func submit(_ cue: SpeechCue) -> Action {
    guard let speaking = current else {
      current = cue
      return .speak(cue, interrupt: false)
    }
    if cue.priority > speaking.priority {
      current = cue
      pending = nil
      return .speak(cue, interrupt: true)
    }
    if let waiting = pending, waiting.priority > cue.priority { return .drop }
    pending = cue  // newer replaces older at the same or lower priority
    return .wait
  }

  /// Call when the current utterance ends. Returns the next cue to speak, if any.
  mutating func finished() -> SpeechCue? {
    current = pending
    pending = nil
    return current
  }

  mutating func clear() {
    current = nil
    pending = nil
  }
}
