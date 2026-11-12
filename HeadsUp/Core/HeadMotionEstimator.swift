import CoreVideo
import Vision

/// Estimates how far the whole image moved sideways between consecutive frames, which is
/// what a head turn looks like to the camera. Uses Vision's translational image registration.
///
/// This is one global shift, so it is only an approximation of head rotation. It is good
/// enough to detect "the head is turning fast" and pause judgment; it is not true compensation.
final class HeadMotionEstimator: @unchecked Sendable {
  private var previous: CVPixelBuffer?

  func reset() { previous = nil }

  /// Horizontal shift of the image content since the last call, in normalized x units
  /// (frame width = 2). Positive = content moved right, i.e. the camera turned left.
  func shift(for buffer: CVPixelBuffer) -> Double {
    defer { previous = buffer }
    guard let previous else { return 0 }
    // The transform moves the previous frame onto the current one: tx is the content's motion.
    let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: previous)
    do {
      try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
    } catch {
      return 0
    }
    guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else { return 0 }
    let width = Double(CVPixelBufferGetWidth(buffer))
    return width > 0 ? Double(observation.alignmentTransform.tx) / width * 2 : 0
  }
}
