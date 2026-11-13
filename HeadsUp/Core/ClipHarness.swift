import CoreVideo
import Foundation

/// The stages after detection, in order. Shared by the live pipeline and the clip harness
/// so both always run the same logic.
struct PipelineStages {
  private var tracker = Tracker()
  private var riskEstimator = RiskEstimator()
  private var alertPolicy = AlertPolicy()
  private let headMotion = HeadMotionEstimator()

  struct Result {
    let tracks: [Track]
    let risk: RiskFrame
    let alert: AlertState
    let frameShift: Double
  }

  mutating func reset() {
    tracker.reset()
    riskEstimator.reset()
    alertPolicy.reset()
    headMotion.reset()
  }

  /// - Parameter scriptedShift: for scripted scenes, the known head-turn shift; nil to measure
  ///   it from the image.
  mutating func run(
    detections: [Detection], pixelBuffer: CVPixelBuffer, scriptedShift: Double?, time: Double, config: PipelineConfig
  ) -> Result {
    // Global image shift since the last processed frame (head turn).
    let frameShift = scriptedShift ?? headMotion.shift(for: pixelBuffer)
    tracker.config = config.tracker
    let tracks = tracker.update(detections, at: time, frameShift: frameShift)
    riskEstimator.config = config.risk
    let risk = riskEstimator.update(tracks: tracks, time: time, frameShift: frameShift)
    alertPolicy.config = config.alert
    let alert = alertPolicy.update(risk: risk, tracks: tracks, time: time)
    return Result(tracks: tracks, risk: risk, alert: alert, frameShift: frameShift)
  }
}

/// Runs a recorded clip through the full pipeline (every frame, not in real time) and
/// produces a per-frame log: track, estimated tau, course, level.
enum ClipHarness {
  struct FrameLog {
    let time: Double
    let unstable: Bool
    let leftLevel: Int
    let rightLevel: Int
    let cues: [String]
    let tracks: [(id: Int, objectClass: ObjectClass, assessment: RiskAssessment?, smoothedLevel: Int)]

    var lines: [String] {
      var out: [String] = []
      let head = String(format: "t=%6.2f  L%d R%d%@", time, leftLevel, rightLevel, unstable ? "  UNSTABLE" : "")
      if tracks.isEmpty { out.append(head + "  (no tracks)") }
      for t in tracks {
        let tau = t.assessment?.tau.map { String(format: "%5.1f", $0) } ?? "    -"
        let state = t.assessment?.state.rawValue ?? "-"
        let side = t.assessment?.side?.rawValue ?? "-"
        out.append(
          head
            + String(
              format: "  #%-3d %-10@ tau(est)=%@ s  %-14@ side=%-5@ level=%d smoothed=%d%@",
              t.id, t.objectClass.rawValue as NSString, tau, state as NSString, side as NSString,
              t.assessment?.level ?? 0, t.smoothedLevel, t.assessment?.held == true ? " held" : ""))
      }
      for cue in cues { out.append(head + "  SPOKEN: \"\(cue)\"") }
      return out
    }
  }

  static func run(url: URL, detector: Detector, config: PipelineConfig = PipelineConfig()) async throws -> [FrameLog] {
    let reader = try await VideoFrameReader(url: url)
    var stages = PipelineStages()
    var logs: [FrameLog] = []
    while let (buffer, time) = reader.next() {
      let detections = try detector.detect(buffer, minConfidence: config.minConfidence)
      let result = stages.run(detections: detections, pixelBuffer: buffer, scriptedShift: nil, time: time, config: config)
      logs.append(
        FrameLog(
          time: time, unstable: result.risk.unstable, leftLevel: result.alert.leftLevel,
          rightLevel: result.alert.rightLevel, cues: result.alert.cues.map(\.text),
          tracks: result.tracks.map {
            ($0.id, $0.objectClass, result.risk[$0.id], result.alert.trackLevels[$0.id] ?? 0)
          }))
    }
    return logs
  }

  static func text(_ logs: [FrameLog]) -> String { logs.flatMap(\.lines).joined(separator: "\n") }
}
