import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

/// Thresholds for the whole pipeline. All configurable from Settings.
struct PipelineConfig: Sendable, Equatable {
  var minConfidence: Float = 0.4
}

/// FrameSource → Detector → (Tracker → RiskEstimator → AlertPolicy, added in later steps).
///
/// Runs off the main thread. If a frame is still being processed when the next arrives,
/// the new frame is DROPPED. Frames are never queued: a late warning is worse than a skipped frame.
final class Pipeline: @unchecked Sendable {
  struct Output: Sendable {
    let timestamp: CFTimeInterval
    /// The processed frame, for display. Boxes line up with this exact image.
    let image: CGImage?
    let detections: [Detection]
    /// Time spent in the detector for this frame, milliseconds. 0 for scripted frames.
    let detectionMs: Double
    /// Frames per second arriving from the source.
    let sourceFPS: Double
    /// Frames per second actually processed (lower when frames are dropped).
    let processedFPS: Double
    let droppedFrames: Int
  }

  var onOutput: (@Sendable (Output) -> Void)?

  private let detector: Detector?
  private let queue = DispatchQueue(label: "headsup.pipeline", qos: .userInitiated)
  private let lock = NSLock()
  private var busy = false
  private var arrivals = FPSMeter()
  private var processed = FPSMeter()
  private var dropped = 0
  private var _config = PipelineConfig()

  init(detector: Detector?) { self.detector = detector }

  var config: PipelineConfig {
    get { lock.withLock { _config } }
    set { lock.withLock { _config = newValue } }
  }

  func reset() {
    lock.withLock {
      arrivals.reset()
      processed.reset()
      dropped = 0
    }
  }

  /// Call from the source's thread, once per frame.
  func process(_ frame: Frame) {
    lock.lock()
    let sourceFPS = arrivals.tick(at: frame.timestamp)
    if busy {
      dropped += 1
      lock.unlock()
      return
    }
    busy = true
    let config = _config
    lock.unlock()

    queue.async { [self] in
      var detections: [Detection] = []
      var detectionMs = 0.0
      if let scripted = frame.scriptedDetections {
        detections = scripted.filter { $0.confidence >= config.minConfidence }
      } else if let detector {
        let start = CACurrentMediaTime()
        detections = (try? detector.detect(frame.pixelBuffer, minConfidence: config.minConfidence)) ?? []
        detectionMs = (CACurrentMediaTime() - start) * 1000
      }
      var image: CGImage?
      VTCreateCGImageFromCVPixelBuffer(frame.pixelBuffer, options: nil, imageOut: &image)

      lock.lock()
      let processedFPS = processed.tick(at: CACurrentMediaTime())
      let droppedNow = dropped
      busy = false
      lock.unlock()

      onOutput?(
        Output(
          timestamp: frame.timestamp, image: image, detections: detections, detectionMs: detectionMs,
          sourceFPS: sourceFPS, processedFPS: processedFPS, droppedFrames: droppedNow))
    }
  }
}
