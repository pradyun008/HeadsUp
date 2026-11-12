import CoreVideo
import Observation
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
    do {
      pipeline = Pipeline(detector: try YOLODetector())
    } catch {
      pipeline = Pipeline(detector: nil)
      detectorMessage = error.localizedDescription
    }
    pipeline.onOutput = { [weak self] output in
      Task { @MainActor in self?.outputArrived(output) }
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
    pipeline.reset()
    fps = 0
    frameCount = 0
    frameSize = .zero
    UIApplication.shared.isIdleTimerDisabled = true
    source.start()
  }

  func stop() {
    source.stop()
    finishWatching()
  }

  private func finishWatching() {
    isWatching = false
    preview = nil
    detections = []
    fps = 0
    processedFPS = 0
    UIApplication.shared.isIdleTimerDisabled = false
  }

  private func statusChanged(_ status: FrameSourceStatus) {
    self.status = status
    switch status {
    case .failed, .needsAction:
      // The source has torn itself down; Start is available again.
      finishWatching()
    default:
      break
    }
  }

  private func outputArrived(_ output: Pipeline.Output) {
    guard isWatching else { return }
    frameCount += 1
    fps = output.sourceFPS
    processedFPS = output.processedFPS
    detectionMs = detectionMs == 0 ? output.detectionMs : 0.9 * detectionMs + 0.1 * output.detectionMs
    droppedFrames = output.droppedFrames
    detections = output.detections
    if let image = output.image {
      preview = image
      frameSize = CGSize(width: image.width, height: image.height)
    }
  }
}
