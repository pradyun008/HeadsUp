import CoreVideo
import Observation
import UIKit
import VideoToolbox

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

  @ObservationIgnored private var meter = FPSMeter()

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
    source.onFrame = { [weak self] frame in
      // Off the main thread: make the display image here, then hop.
      var image: CGImage?
      VTCreateCGImageFromCVPixelBuffer(frame.pixelBuffer, options: nil, imageOut: &image)
      Task { @MainActor in self?.frameArrived(frame, image: image) }
    }
  }

  func start() {
    isWatching = true
    meter.reset()
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
    fps = 0
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

  private func frameArrived(_ frame: Frame, image: CGImage?) {
    guard isWatching else { return }
    frameCount += 1
    fps = meter.tick(at: frame.timestamp)
    if let image {
      preview = image
      frameSize = CGSize(width: image.width, height: image.height)
    }
  }
}
