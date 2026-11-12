import CoreVideo
import Observation
import UIKit
import VideoToolbox

/// App state: the active frame source, its status, and the latest frame for display.
@Observable
@MainActor
final class AppModel {
  let glasses: GlassesFrameSource

  private(set) var status: FrameSourceStatus = .idle
  private(set) var isWatching = false
  private(set) var fps = 0.0
  private(set) var frameCount = 0
  private(set) var preview: CGImage?
  private(set) var frameSize: CGSize = .zero

  @ObservationIgnored private var source: any FrameSource
  @ObservationIgnored private var meter = FPSMeter()

  init(glasses: GlassesFrameSource) {
    self.glasses = glasses
    self.source = glasses
    attach(glasses)
  }

  var sourceName: String { source.displayName }

  private func attach(_ source: any FrameSource) {
    source.onStatusChange = { [weak self] status in self?.statusChanged(status) }
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
