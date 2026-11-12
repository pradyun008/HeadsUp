import AVFoundation

/// Speaks short cues ("bike, left") and status notices through the current audio route.
/// With the glasses connected as a Bluetooth audio device, that route is the glasses' speakers.
/// Other audio (music, a podcast) is ducked while a cue plays and restored afterwards.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var queue = SpeechQueue()
  private(set) var lastSpoken: String?
  var onSpoken: ((String) -> Void)?

  override init() {
    super.init()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
  }

  func speak(_ cue: SpeechCue) {
    switch queue.submit(cue) {
    case .speak(let cue, let interrupt):
      if interrupt { synthesizer.stopSpeaking(at: .immediate) }
      start(cue)
    case .wait, .drop:
      break
    }
  }

  func stopAll() {
    queue.clear()
    synthesizer.stopSpeaking(at: .immediate)
    deactivate()
  }

  private func start(_ cue: SpeechCue) {
    let session = AVAudioSession.sharedInstance()
    // .playback routes to a connected Bluetooth audio device (the glasses) and plays with the
    // silent switch on. .duckOthers lowers other audio for the cue instead of stopping it.
    try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
    try? session.setActive(true)
    let utterance = AVSpeechUtterance(string: cue.text)
    utterance.rate = 0.54  // a little faster than default: cues must be short
    utterance.preUtteranceDelay = 0
    utterance.postUtteranceDelay = 0
    synthesizer.speak(utterance)
    lastSpoken = cue.text
    onSpoken?(cue.text)
  }

  private func deactivate() {
    // Lets ducked audio come back to full volume.
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in
      if let next = self.queue.finished() { self.start(next) } else { self.deactivate() }
    }
  }

  // An interrupted utterance reports didCancel; the interrupting cue is already current, so do nothing.
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}
}
