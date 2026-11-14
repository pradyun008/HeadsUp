import Foundation

/// Decides what is spoken when hazard warnings and navigation cues compete, so the glasses never
/// talk over themselves.
///
/// Order of importance, highest first:
///   5  urgent hazard (level 3)
///   4  high hazard (level 2)
///   3  "Turn left", arrival, "Rerouting"
///   2  advance turn notice, start cue, after-turn cue
///   1  "Continue straight", app status ("Watching")
///
/// Rules:
/// - Hazard and status cues go through the existing `SpeechQueue` unchanged, so hazard speech
///   behaves exactly as it did before navigation existed.
/// - A hazard cuts off a navigation cue mid-sentence. The cut-off cue waits and is spoken again
///   afterwards, re-worded for the wearer's new position (never the stale distance), or dropped
///   if it no longer applies.
/// - No navigation cue starts while a hazard level is 2 or 3. "Continue straight" is skipped
///   while any hazard level is above 0.
/// - At most one navigation cue waits. A newer one replaces it.
struct SpeechArbiter: Sendable {
  enum Action: Equatable {
    /// Start speaking this now. `interrupt` means stop the current utterance first.
    case speak(String, interrupt: Bool)
    case wait
    case drop
  }

  /// Re-words a waiting navigation cue for the current position. Returns nil to drop it.
  typealias Refresh = (NavCue) -> NavCue?

  private var hazards = SpeechQueue()
  private(set) var speakingNav: NavCue?
  private(set) var waitingNav: NavCue?
  /// A status cue that arrived while a navigation cue was being spoken.
  private var waitingStatus: SpeechCue?
  /// The higher of the left and right hazard levels, 0–3.
  private(set) var hazardLevel = 0

  /// What is being spoken now, for the debug screen.
  var speakingText: String? { speakingNav?.text ?? hazards.current?.text }
  /// What is waiting to be spoken, for the debug screen.
  var waitingText: String? { hazards.pending?.text ?? waitingStatus?.text ?? waitingNav?.text }

  static func rank(_ cue: SpeechCue) -> Int {
    switch cue.priority {
    case 3...: return 5
    case 2: return 4
    default: return 1
    }
  }

  static func rank(_ cue: NavCue) -> Int {
    switch cue.kind {
    case .imminent, .arrival, .reroute: return 3
    case .advance, .start, .afterTurn, .wrongWay: return 2
    case .reassurance: return 1
    }
  }

  /// A hazard cue ("bike, left") or an app status cue ("Watching").
  mutating func submit(_ cue: SpeechCue) -> Action {
    if let nav = speakingNav {
      guard Self.rank(cue) > Self.rank(nav) else {
        // Status does not interrupt navigation; it waits its turn.
        waitingStatus = cue
        return .wait
      }
      // Cut off the navigation cue. It is replayed later unless a newer one is already waiting.
      if waitingNav == nil { waitingNav = nav }
      speakingNav = nil
      _ = hazards.submit(cue)
      return .speak(cue.text, interrupt: true)
    }
    switch hazards.submit(cue) {
    case .speak(let cue, let interrupt): return .speak(cue.text, interrupt: interrupt)
    case .wait: return .wait
    case .drop: return .drop
    }
  }

  /// A navigation cue ("In about 150 feet, turn left").
  mutating func submit(_ cue: NavCue) -> Action {
    if cue.kind == .reassurance, hazardLevel >= 1 { return .drop }
    if hazardLevel >= 2 { return hold(cue) }
    if let speaking = hazards.current {
      guard Self.rank(cue) > Self.rank(speaking) else { return hold(cue) }
      // Only a status cue can be outranked here; a hazard never is.
      hazards.clear()
      speakingNav = cue
      return .speak(cue.text, interrupt: true)
    }
    if let speaking = speakingNav {
      guard Self.rank(cue) > Self.rank(speaking) else { return hold(cue) }
      // "Turn left" replaces the advance notice it follows; the older cue is not replayed.
      speakingNav = cue
      return .speak(cue.text, interrupt: true)
    }
    speakingNav = cue
    return .speak(cue.text, interrupt: false)
  }

  private mutating func hold(_ cue: NavCue) -> Action {
    if let waiting = waitingNav, Self.rank(waiting) > Self.rank(cue) { return .drop }
    waitingNav = cue
    return .wait
  }

  /// Call when the current utterance ends. Returns the next text to speak, if any.
  mutating func finished(refresh: Refresh) -> String? {
    if speakingNav != nil {
      speakingNav = nil
      if let status = waitingStatus {
        waitingStatus = nil
        _ = hazards.submit(status)
        return status.text
      }
    } else if let next = hazards.finished() {
      return next.text
    }
    return releaseNav(refresh)
  }

  /// Call whenever the hazard levels change. Returns a held navigation cue to speak now, if the
  /// hazard has passed and nothing else is being said.
  mutating func setHazardLevel(_ level: Int, refresh: Refresh) -> String? {
    hazardLevel = level
    return releaseNav(refresh)
  }

  private mutating func releaseNav(_ refresh: Refresh) -> String? {
    guard hazards.current == nil, speakingNav == nil, hazardLevel < 2, let waiting = waitingNav else { return nil }
    waitingNav = nil
    // Always re-word: time has passed since the cue was made.
    guard let fresh = refresh(waiting) else { return nil }
    if fresh.kind == .reassurance, hazardLevel >= 1 { return nil }
    speakingNav = fresh
    return fresh.text
  }

  /// Forget navigation cues (navigation was stopped). Hazard speech is untouched.
  /// Returns true if a navigation cue was being spoken and should be cut off.
  mutating func clearNav() -> Bool {
    waitingNav = nil
    let wasSpeaking = speakingNav != nil
    speakingNav = nil
    return wasSpeaking
  }

  mutating func clear() {
    hazards.clear()
    speakingNav = nil
    waitingNav = nil
    waitingStatus = nil
  }
}
