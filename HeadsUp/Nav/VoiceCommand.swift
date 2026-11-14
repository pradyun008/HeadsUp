import AVFoundation
import AudioToolbox
import Speech

/// What the wearer asked for after pressing the button.
enum VoiceCommand: Equatable, Sendable {
  /// "Take me to McDonald's" → `.destination("mcdonald's")`.
  case destination(String)
  /// "Stop" or "cancel": end navigation.
  case stop
  /// Nothing usable was heard.
  case none

  private static let leadIns = [
    "i want to go to", "i wanna go to", "i would like to go to", "i'd like to go to", "i need to go to",
    "take me to", "bring me to", "walk me to", "guide me to", "navigate to", "directions to",
    "get me to", "go to", "find",
  ]
  private static let fillers: Set<String> = ["um", "uh", "hmm", "er", "ah", "okay", "ok", "hey", "please"]

  /// Reads a speech transcript. Pure text handling, so it is unit-tested without a microphone.
  static func parse(_ transcript: String) -> VoiceCommand {
    var text = transcript.lowercased()
      .replacingOccurrences(of: "’", with: "'")
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    guard !text.isEmpty else { return .none }

    // A destination request wins over a stray "stop" inside it ("take me to the bus stop").
    for lead in leadIns {
      guard let range = text.range(of: lead), range.lowerBound == text.startIndex || text[..<range.lowerBound].last == " " else { continue }
      text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
      return place(text).map(VoiceCommand.destination) ?? .none
    }

    let words = text.split(separator: " ").map(String.init)
    if words.contains("stop") || words.contains("cancel") { return .stop }
    // The button press already showed intent, so a bare place name counts ("McDonald's").
    return place(text).map(VoiceCommand.destination) ?? .none
  }

  /// Strips filler and "the nearest" from a place phrase. Nil if nothing meaningful is left.
  private static func place(_ phrase: String) -> String? {
    var words = phrase.split(separator: " ").map(String.init).filter { !fillers.contains($0) }
    while let first = words.first, ["the", "a", "an", "my", "nearest", "closest", "nearby"].contains(first) {
      words.removeFirst()
    }
    let result = words.joined(separator: " ")
    return result.filter(\.isLetter).count >= 3 ? result : nil
  }
}

/// Opens the microphone for a few seconds and returns what was said.
///
/// The microphone is open ONLY during this window. Keeping a Bluetooth microphone open all the
/// time would force the glasses into low-quality headset audio and compete with the camera
/// stream, which uses the same Bluetooth link.
@MainActor
final class VoiceListener {
  /// Longest listening window.
  var maxSeconds = 6.0
  /// Listening ends this long after the last new word.
  var silenceSeconds = 1.2

  private let engine = AVAudioEngine()
  private var task: SFSpeechRecognitionTask?
  private var finish: ((String?) -> Void)?
  /// Counts listening windows, so a timer left over from an earlier window cannot end a later one.
  private var window = 0

  /// Asks for microphone and speech-recognition permission. Returns a message if either is refused.
  func requestPermission() async -> String? {
    let speech = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard speech == .authorized else { return "Speech recognition permission needed. Turn it on in Settings." }
    let mic = await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
    }
    return mic ? nil : "Microphone permission needed. Turn it on in Settings."
  }

  /// Listens once. Returns the transcript, or nil if nothing was heard or listening was cancelled.
  func listen() async -> String? {
    guard finish == nil else { return nil }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else { return nil }

    let session = AVAudioSession.sharedInstance()
    do {
      // .allowBluetooth makes the glasses' microphone usable. With no Bluetooth headset the phone's is used.
      try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .duckOthers])
      try session.setActive(true)
    } catch {
      return nil
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    // On-device only: nothing the wearer says leaves the phone.
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    engine.prepare()
    do { try engine.start() } catch {
      input.removeTap(onBus: 0)
      return nil
    }
    AudioServicesPlaySystemSound(1113)  // short "listening" tone

    window += 1
    let thisWindow = window
    return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      var latest = ""
      var silenceTimer: Task<Void, Never>?
      finish = { [weak self] result in
        guard let self, self.finish != nil else { return }
        self.finish = nil
        silenceTimer?.cancel()
        self.engine.stop()
        input.removeTap(onBus: 0)
        request.endAudio()
        self.task?.cancel()
        self.task = nil
        AudioServicesPlaySystemSound(1114)  // short "done" tone
        continuation.resume(returning: result)
      }
      task = recognizer.recognitionTask(with: request) { result, error in
        let text = result?.bestTranscription.formattedString
        let ended = result?.isFinal == true || error != nil
        Task { @MainActor [weak self] in
          guard let self, self.finish != nil else { return }
          if let text, text != latest {
            latest = text
            // Restart the silence countdown on every new word.
            silenceTimer?.cancel()
            silenceTimer = Task { @MainActor [weak self] in
              try? await Task.sleep(nanoseconds: UInt64((self?.silenceSeconds ?? 1.2) * 1_000_000_000))
              if !Task.isCancelled { self?.finish?(latest.isEmpty ? nil : latest) }
            }
          }
          if ended { self.finish?(latest.isEmpty ? nil : latest) }
        }
      }
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64((self?.maxSeconds ?? 6) * 1_000_000_000))
        guard let self, self.window == thisWindow else { return }
        self.finish?(latest.isEmpty ? nil : latest)
      }
    }
  }

  /// Stops listening at once and discards what was heard. Used when a hazard must be spoken.
  func cancel() { finish?(nil) }

  var isListening: Bool { finish != nil }
}
