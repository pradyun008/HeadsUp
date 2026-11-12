import CoreML
import CoreVideo
import Vision

/// Finds objects in one frame. Runs on-device only (no cloud in the hazard loop).
protocol Detector: Sendable {
  /// Called off the main thread. Returns only the kept classes at or above `minConfidence`.
  func detect(_ pixelBuffer: CVPixelBuffer, minConfidence: Float) throws -> [Detection]
}

enum DetectorError: LocalizedError {
  case modelMissing

  var errorDescription: String? {
    "Detection model missing. Run: sh tools/export_model.sh (puts yolo11n.mlpackage in HeadsUp/Resources/)"
  }
}

/// YOLO11n exported to Core ML with NMS included, run through Vision.
final class YOLODetector: Detector, @unchecked Sendable {
  private let model: VNCoreMLModel

  init() throws {
    guard let url = Bundle.main.url(forResource: "yolo11n", withExtension: "mlmodelc") else {
      throw DetectorError.modelMissing
    }
    let config = MLModelConfiguration()
    config.computeUnits = .all
    model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
  }

  func detect(_ pixelBuffer: CVPixelBuffer, minConfidence: Float) throws -> [Detection] {
    let request = VNCoreMLRequest(model: model)
    // Stretch the whole frame onto the model's square input, so the boxes Vision
    // returns map exactly back onto the full frame (no crop, no letterbox offset).
    request.imageCropAndScaleOption = .scaleFill
    try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])
    let observations = request.results as? [VNRecognizedObjectObservation] ?? []
    return observations.compactMap { Self.detection(from: $0, minConfidence: minConfidence) }
  }

  /// Vision boxes are 0…1 with the origin at the bottom-left. HeadsUp uses camera-relative
  /// x from −1 (left edge) to +1 (right edge) and y from 0 (top) to 1 (bottom).
  static func detection(from observation: VNRecognizedObjectObservation, minConfidence: Float) -> Detection? {
    // Threshold on observation.confidence (the detector's score). The label's own
    // confidence is renormalized across classes by Vision and sits near 1.0.
    guard observation.confidence >= minConfidence, let label = observation.labels.first,
      let objectClass = ObjectClass(rawValue: label.identifier)  // drops every class we don't keep
    else { return nil }
    let box = observation.boundingBox
    return Detection(
      objectClass: objectClass, confidence: observation.confidence,
      left: Double(box.minX) * 2 - 1, right: Double(box.maxX) * 2 - 1,
      top: 1 - Double(box.maxY), bottom: 1 - Double(box.minY))
  }
}
