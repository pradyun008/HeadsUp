import CoreVideo
import Observation
import QuartzCore
import UIKit

/// App state: the active frame source, its status, and the latest frame for display.
@Observable
@MainActor
final class AppModel {
  enum SourceKind: String, CaseIterable, Identifiable {
    case glasses, phoneCamera, scenario
    var id: String { rawValue }
    var label: String {
      switch self {
      case .glasses: return "Glasses"
      case .phoneCamera: return "Phone camera"
      case .scenario: return "Scripted scene"
      }
    }
  }

  let glasses: GlassesFrameSource
  let phoneCamera = PhoneCameraFrameSource()
  let scenarioSource = ScenarioFrameSource()

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
    }
  }

  init(glasses: GlassesFrameSource) {
    self.glasses = glasses
    let saved = UserDefaults.standard.string(forKey: "sourceKind").flatMap(SourceKind.init(rawValue:))
    self.sourceKind = saved ?? .glasses
    self.scenarioName = scenarioSource.scenario.name
    self.swapBandChannels = UserDefaults.standard.bool(forKey: "swapBandChannels")
    self.band = BandOutput(transport: simulatedBand)
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
    band.swapChannels = swapBandChannels
    let band = self.band
    pipeline.onOutput = { [weak self] output in
      // Straight to the band from the pipeline thread: no hop through the main thread.
      band.setLevels(left: output.alert.leftLevel, right: output.alert.rightLevel)
      // End-to-end: frame reached the app → its levels were handed to the band.
      let latencyMs = (CACurrentMediaTime() - output.timestamp) * 1000
      Task { @MainActor in self?.outputArrived(output, latencyMs: latencyMs) }
    }
    simulatedBand.onWrite = { [weak self] packet, _ in
      Task { @MainActor in self?.bandWrote(packet) }
    }
    attach(glasses, kind: .glasses)
    attach(phoneCamera, kind: .phoneCamera)
    attach(scenarioSource, kind: .scenario)
  }

  var sourceName: String { source.displayName }

  private func attach(_ source: any FrameSource, kind: SourceKind) {
    source.onStatusChange = { [weak self] status in
      // Ignore sources that are not selected.
      guard let self, self.sourceKind == kind else { return }
      self.statusChanged(status)
    }
    // Off the main thread: straight into the pipeline, which drops frames while busy.
    let pipeline = self.pipeline
    source.onFrame = { frame in pipeline.process(frame) }
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

  private func finishWatching() {
    isWatching = false
    band.stop()
    preview = nil
    detections = []
    tracks = []
    risk = RiskFrame()
    leftLevel = 0
    rightLevel = 0
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
    leftLevel = output.alert.leftLevel
    rightLevel = output.alert.rightLevel
    for cue in output.alert.cues {
      lastCue = cue.text
      if speechEnabled { speech.speak(cue) }
    }
    if let image = output.image {
      preview = image
      frameSize = CGSize(width: image.width, height: image.height)
    }
  }
}
