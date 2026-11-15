import CoreVideo
import Observation
import QuartzCore
import UIKit

/// App state: the active frame source, its status, and the latest frame for display.
@Observable
@MainActor
final class AppModel {
  enum SourceKind: String, CaseIterable, Identifiable {
    case glasses, phoneCamera, scenario, videoFile
    var id: String { rawValue }
    var label: String {
      switch self {
      case .glasses: return "Glasses"
      case .phoneCamera: return "Phone"
      case .scenario: return "Scripted"
      case .videoFile: return "Video"
      }
    }
  }

  let glasses: GlassesFrameSource
  let phoneCamera = PhoneCameraFrameSource()
  let scenarioSource = ScenarioFrameSource()
  let videoSource = VideoFileFrameSource()

  /// Video files in the app's Documents folder (recordings, and clips copied in with Finder or Files).
  private(set) var videoFiles: [URL] = []
  var videoFileName: String = "" {
    didSet { videoSource.url = videoFiles.first { $0.lastPathComponent == videoFileName } }
  }
  private(set) var isRecording = false
  private(set) var recordingMessage: String?
  @ObservationIgnored private let recorderBox = RecorderBox()

  /// Which source Start uses. Can only change while stopped.
  var sourceKind: SourceKind {
    didSet {
      guard sourceKind != oldValue else { return }
      UserDefaults.standard.set(sourceKind.rawValue, forKey: "sourceKind")
      status = .idle
    }
  }
  var scenarioName: String {
    didSet {
      if let s = Scenario.all.first(where: { $0.name == scenarioName }) { scenarioSource.scenario = s }
    }
  }

  private(set) var status: FrameSourceStatus = .idle
  private(set) var isWatching = false
  private(set) var fps = 0.0
  private(set) var frameCount = 0
  private(set) var preview: CGImage?
  private(set) var frameSize: CGSize = .zero
  private(set) var detections: [Detection] = []
  private(set) var tracks: [Track] = []
  private(set) var risk = RiskFrame()
  /// Priority: the most urgent object right now (lowest tau), from AlertPolicy.
  private(set) var topTrackID: Int?
  /// The step detector's shake in g (walking above `MeasuredConstants.stepWobbleStart`).
  private(set) var stepWobble = 0.0
  /// Smoothed output levels, 0–3. "Left" and "right" are camera-relative.
  private(set) var leftLevel = 0
  private(set) var rightLevel = 0
  private(set) var lastCue: String?
  /// What the (simulated) band's two motors are doing: the bytes last written to it.
  private(set) var bandPacket: [UInt8] = [0, 0]
  private(set) var bandWriteRate = 0.0
  /// "Which wrist": exchanges the two cues sent to the band.
  var swapBandChannels: Bool {
    didSet {
      UserDefaults.standard.set(swapBandChannels, forKey: "swapBandChannels")
      band.swapChannels = swapBandChannels
    }
  }
  /// Where the left/right cues are felt.
  enum HapticsOutput: String, CaseIterable, Identifiable {
    case band, phone, both
    var id: String { rawValue }
    var label: String {
      switch self {
      case .band: return "Band"
      case .phone: return "Phone"
      case .both: return "Both"
      }
    }
  }
  var hapticsOutput: HapticsOutput {
    didSet {
      UserDefaults.standard.set(hapticsOutput.rawValue, forKey: "hapticsOutput")
      outputSwitch.set(band: hapticsOutput != .phone, phone: hapticsOutput != .band)
      if hapticsOutput == .band { phoneHaptics.stop() }
      if hapticsOutput == .phone { band.setLevels(left: 0, right: 0) }
    }
  }
  let phoneHapticsSupported = PhoneHapticOutput.isSupported
  @ObservationIgnored private let phoneHaptics = PhoneHapticOutput()
  /// Phone activity + pedometer → the wearer's walking state for "Is it moving?".
  @ObservationIgnored private let motion = MotionSource()
  @ObservationIgnored private let outputSwitch = OutputSwitch()
  @ObservationIgnored private let simulatedBand = SimulatedBand()
  @ObservationIgnored private let band: BandOutput
  /// Voice on/off.
  var speechEnabled: Bool {
    didSet {
      UserDefaults.standard.set(speechEnabled, forKey: "speechEnabled")
      if !speechEnabled { speech.stopAll() }
    }
  }
  @ObservationIgnored private let speech = SpeechOutput()
  /// Walking navigation. Voice only: the band stays hazard-only, so a buzz always means a hazard.
  let nav = NavController()
  /// True once frames have flowed since Start; decides between "Watching" and "Watching resumed".
  @ObservationIgnored private var hasRun = false
  @ObservationIgnored private var wasInterrupted = false
  var corridor: Double { config.risk.corridor }
  /// All thresholds. Applied to the pipeline at once and saved.
  var config: PipelineConfig {
    didSet {
      let fixed = config.normalized()
      if fixed != config { config = fixed; return }
      pipeline.config = config
      if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: "pipelineConfig") }
    }
  }
  /// Rolling average, milliseconds, from a frame reaching the app to the band write for it.
  private(set) var endToEndMs = 0.0
  @ObservationIgnored private var latencies: [Double] = []
  private(set) var processedFPS = 0.0
  private(set) var detectionMs = 0.0
  private(set) var droppedFrames = 0
  /// Set when the detection model could not be loaded.
  private(set) var detectorMessage: String?

  @ObservationIgnored private let pipeline: Pipeline
  private var source: any FrameSource {
    switch sourceKind {
    case .glasses: return glasses
    case .phoneCamera: return phoneCamera
    case .scenario: return scenarioSource
    case .videoFile: return videoSource
    }
  }

  init(glasses: GlassesFrameSource) {
    self.glasses = glasses
    let saved = UserDefaults.standard.string(forKey: "sourceKind").flatMap(SourceKind.init(rawValue:))
    self.sourceKind = saved ?? .glasses
    self.scenarioName = scenarioSource.scenario.name
    self.swapBandChannels = UserDefaults.standard.bool(forKey: "swapBandChannels")
    self.band = BandOutput(transport: simulatedBand)
    let savedOutput = UserDefaults.standard.string(forKey: "hapticsOutput").flatMap(HapticsOutput.init(rawValue:))
    let output = savedOutput ?? .band
    self.hapticsOutput = output
    outputSwitch.set(band: output != .phone, phone: output != .band)
    self.speechEnabled = UserDefaults.standard.object(forKey: "speechEnabled") as? Bool ?? true
    let savedConfig = UserDefaults.standard.data(forKey: "pipelineConfig")
      .flatMap { try? JSONDecoder().decode(PipelineConfig.self, from: $0) }
    self.config = (savedConfig ?? PipelineConfig()).normalized()
    do {
      pipeline = Pipeline(detector: try YOLODetector())
    } catch {
      pipeline = Pipeline(detector: nil)
      detectorMessage = error.localizedDescription
    }
    pipeline.config = config
    let motion = self.motion
    pipeline.wearerMotion = { motion.current }
    band.swapChannels = swapBandChannels
    let band = self.band
    let phoneHaptics = self.phoneHaptics
    let outputSwitch = self.outputSwitch
    pipeline.onOutput = { [weak self] output in
      // Straight to the band from the pipeline thread: no hop through the main thread.
      let enabled = outputSwitch.get()
      if enabled.band { band.setLevels(left: output.alert.leftLevel, right: output.alert.rightLevel) }
      if enabled.phone { phoneHaptics.setLevels(left: output.alert.leftLevel, right: output.alert.rightLevel) }
      // End-to-end: frame reached the app → its levels were handed to the band.
      let latencyMs = (CACurrentMediaTime() - output.timestamp) * 1000
      Task { @MainActor in self?.outputArrived(output, latencyMs: latencyMs) }
    }
    simulatedBand.onWrite = { [weak self] packet, _ in
      Task { @MainActor in self?.bandWrote(packet) }
    }
    connectNavigation()
    attach(glasses, kind: .glasses)
    attach(phoneCamera, kind: .phoneCamera)
    attach(scenarioSource, kind: .scenario)
    attach(videoSource, kind: .videoFile)
    refreshVideoFiles()
  }

  var sourceName: String { source.displayName }

  /// What the speech arbiter is holding back right now, for the Route debug screen.
  var waitingSpeech: String? { speech.waitingText }

  /// The table demo, from one control: replays a saved walk for navigation and, if a recorded
  /// video is available, plays it through the hazard pipeline at the same time.
  /// Needs no GPS, no network and no glasses. The hazard check still uses the phone's real
  /// motion sensors, so a wearer standing at the table counts as standing still.
  func startReplayDemo(_ walk: SavedWalk, speed: Double = 1) {
    if !isWatching {
      refreshVideoFiles()
      if !videoFiles.isEmpty { sourceKind = .videoFile }
      start()
    }
    nav.replay(walk, speed: speed)
  }

  /// Navigation speaks through the same speech output as hazards, which always puts hazards first.
  private func connectNavigation() {
    let speech = self.speech
    nav.speakCue = { [weak self] cue in
      guard self?.speechEnabled == true else { return }
      speech.speak(cue)
    }
    nav.speakNotice = { [weak self] text in
      guard self?.speechEnabled == true else { return }
      speech.speak(SpeechCue(text: text, priority: 0, trackID: nil))
    }
    nav.stopSpeech = { speech.stopNavigationSpeech() }
    nav.listeningChanged = { speech.microphoneOpen = $0 }
    // A navigation cue delayed by a hazard is re-worded for the wearer's new position.
    speech.refreshNav = { [weak nav] cue in nav?.engine.refreshed(cue) }
    speech.onFinished = { [weak nav] text in nav?.spoke(text) }
    nav.activate()
  }

  private func attach(_ source: any FrameSource, kind: SourceKind) {
    source.onStatusChange = { [weak self] status in
      // Ignore sources that are not selected.
      guard let self, self.sourceKind == kind else { return }
      self.statusChanged(status)
    }
    // Off the main thread: straight into the pipeline, which drops frames while busy.
    let pipeline = self.pipeline
    let recorderBox = self.recorderBox
    source.onFrame = { frame in
      recorderBox.recorder?.append(frame.pixelBuffer, at: frame.timestamp)  // every incoming frame
      pipeline.process(frame)
    }
  }

  func start() {
    isWatching = true
    hasRun = false
    wasInterrupted = false
    lastCue = nil
    latencies = []
    endToEndMs = 0
    detectionMs = 0
    pipeline.reset()
    fps = 0
    frameCount = 0
    frameSize = .zero
    UIApplication.shared.isIdleTimerDisabled = true
    band.start()
    motion.start()
    source.start()
  }

  func stop() {
    source.stop()
    finishWatching()
  }

  private func bandWrote(_ packet: [UInt8]) {
    bandPacket = packet
    bandWriteRate = simulatedBand.writeRate
  }

  func refreshVideoFiles() {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let all = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
    videoFiles = all.filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
    if !videoFiles.contains(where: { $0.lastPathComponent == videoFileName }) {
      videoFileName = videoFiles.first?.lastPathComponent ?? ""
    } else {
      videoSource.url = videoFiles.first { $0.lastPathComponent == videoFileName }
    }
  }

  /// Starts or stops saving incoming frames to a .mov in Documents.
  func toggleRecording() {
    if let recorder = recorderBox.recorder {
      recorderBox.recorder = nil
      isRecording = false
      Task {
        let url = await recorder.finish()
        recordingMessage = url.map { "Saved \($0.lastPathComponent) (\(recorder.frameCount) frames)" } ?? "Recording failed: no frames saved"
        refreshVideoFiles()
      }
    } else {
      let recorder = FrameRecorder(url: FrameRecorder.newDocumentsURL())
      recorderBox.recorder = recorder
      isRecording = true
      recordingMessage = "Recording to \(recorder.url.lastPathComponent)"
    }
  }

  private func finishWatching() {
    if isRecording { toggleRecording() }
    isWatching = false
    band.stop()
    phoneHaptics.stop()
    motion.stop()
    preview = nil
    detections = []
    tracks = []
    risk = RiskFrame()
    leftLevel = 0
    rightLevel = 0
    speech.setHazardLevel(0)  // nothing is being watched, so nothing holds navigation speech back
    fps = 0
    processedFPS = 0
    UIApplication.shared.isIdleTimerDisabled = false
  }

  private func statusChanged(_ status: FrameSourceStatus) {
    self.status = status
    announce(status)
    switch status {
    case .failed, .needsAction:
      // The source has torn itself down; Start is available again.
      finishWatching()
    default:
      break
    }
  }

  /// Spoken status for a wearer who cannot see the screen: started, lost/paused, resumed.
  /// These only report the app's state. Hazard cues always take priority over them.
  private func announce(_ status: FrameSourceStatus) {
    guard speechEnabled, isWatching else { return }
    var text: String?
    switch status {
    case .running:
      text = !hasRun ? "Watching" : wasInterrupted ? "Watching resumed" : nil
      hasRun = true
      wasInterrupted = false
    case .interrupted(let message), .failed(let message), .needsAction(let message):
      wasInterrupted = true
      text = message
    case .idle, .starting:
      break
    }
    if let text { speech.speak(SpeechCue(text: text, priority: 0, trackID: nil)) }
  }

  private func outputArrived(_ output: Pipeline.Output, latencyMs: Double) {
    guard isWatching else { return }
    latencies.append(latencyMs)
    if latencies.count > 30 { latencies.removeFirst() }
    endToEndMs = latencies.reduce(0, +) / Double(latencies.count)
    frameCount += 1
    fps = output.sourceFPS
    processedFPS = output.processedFPS
    detectionMs = detectionMs == 0 ? output.detectionMs : 0.9 * detectionMs + 0.1 * output.detectionMs
    droppedFrames = output.droppedFrames
    detections = output.detections
    tracks = output.tracks
    risk = output.risk
    topTrackID = output.alert.topTrackID
    stepWobble = motion.wobble
    leftLevel = output.alert.leftLevel
    rightLevel = output.alert.rightLevel
    // Navigation speech is held while a hazard is high or urgent, and released when it passes.
    speech.setHazardLevel(max(leftLevel, rightLevel))
    for cue in output.alert.cues {
      // A hazard is never delayed by a spoken request: the microphone closes and the request is dropped.
      if cue.priority >= 2 { nav.cancelListening() }
      lastCue = cue.text
      if speechEnabled { speech.speak(cue) }
    }
    if let image = output.image {
      preview = image
      frameSize = CGSize(width: image.width, height: image.height)
    }
  }
}

/// Holds the active recorder where the frame thread can reach it.
final class RecorderBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _recorder: FrameRecorder?
  var recorder: FrameRecorder? {
    get { lock.withLock { _recorder } }
    set { lock.withLock { _recorder = newValue } }
  }
}

/// Which haptic outputs are on, readable from the pipeline thread.
final class OutputSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var band = true
  private var phone = false
  func set(band: Bool, phone: Bool) { lock.withLock { self.band = band; self.phone = phone } }
  func get() -> (band: Bool, phone: Bool) { lock.withLock { (band, phone) } }
}
