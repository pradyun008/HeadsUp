import AVFoundation

/// Speaks short cues ("bike, left") and status notices through the current audio route.
/// With the glasses connected as a Bluetooth audio device, that route is the glasses' speakers.
/// Other audio (music, a podcast) is ducked while a cue plays and restored afterwards.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  /// Orders hazard, navigation and status speech. Hazard cues behave as before navigation existed.
  private var arbiter = SpeechArbiter()
  private(set) var lastSpoken: String?
  var onSpoken: ((String) -> Void)?
  /// Re-words a delayed navigation cue for the wearer's current position, or returns nil to drop it.
  /// Set by whoever owns the navigation engine.
  var refreshNav: SpeechArbiter.Refresh = { $0 }
  /// What is waiting to be spoken, for the debug screen.
  var waitingText: String? { arbiter.waitingText }

  override init() {
    super.init()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
  }

  /// A hazard cue ("bike, left") or an app status cue ("Watching").
  func speak(_ cue: SpeechCue) { perform(arbiter.submit(cue)) }

  /// A navigation cue ("In about 150 feet, turn left"). Hazard cues always go first.
  func speak(_ cue: NavCue) { perform(arbiter.submit(cue)) }

  /// Tell the speech output the current hazard level (the higher of left and right, 0–3).
  /// Navigation cues are held while it is 2 or 3 and released when it falls.
  func setHazardLevel(_ level: Int) {
    guard level != arbiter.hazardLevel else { return }
    if let text = arbiter.setHazardLevel(level, refresh: refreshNav) { start(text) }
  }

  /// Navigation was stopped: forget its cues and cut off one that is being spoken.
  func stopNavigationSpeech() {
    if arbiter.clearNav() { synthesizer.stopSpeaking(at: .immediate) }
  }

  private func perform(_ action: SpeechArbiter.Action) {
    switch action {
    case .speak(let text, let interrupt):
      if interrupt { synthesizer.stopSpeaking(at: .immediate) }
      start(text)
    case .wait, .drop:
      break
    }
  }

  func stopAll() {
    arbiter.clear()
    synthesizer.stopSpeaking(at: .immediate)
    deactivate()
  }

  private func start(_ text: String) {
    let session = AVAudioSession.sharedInstance()
    // .playback routes to a connected Bluetooth audio device (the glasses) and plays with the
    // silent switch on. .duckOthers lowers other audio for the cue instead of stopping it.
    try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
    try? session.setActive(true)
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = 0.54  // a little faster than default: cues must be short
    utterance.preUtteranceDelay = 0
    utterance.postUtteranceDelay = 0
    synthesizer.speak(utterance)
    lastSpoken = text
    onSpoken?(text)
  }

  private func deactivate() {
    // Lets ducked audio come back to full volume.
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in
      if let next = self.arbiter.finished(refresh: self.refreshNav) { self.start(next) } else { self.deactivate() }
    }
  }

  // An interrupted utterance reports didCancel; the interrupting cue is already current, so do nothing.
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}
}
