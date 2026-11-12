import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore

/// Plays a scripted `Scenario`: draws a simple picture of the scene and attaches the
/// matching detections to each frame, so the tracker, risk and alert stages can be seen
/// working with no camera and no YOLO model. Left/right are camera-relative, as everywhere.
@MainActor
final class ScenarioFrameSource: FrameSource {
  let displayName = "Scripted scene"
  private(set) var status: FrameSourceStatus = .idle {
    didSet { if status != oldValue { onStatusChange?(status) } }
  }
  var onFrame: (@Sendable (Frame) -> Void)?
  var onStatusChange: ((FrameSourceStatus) -> Void)?

  var scenario: Scenario = .demo
  static let frameRate = 15.0
  static let size = (width: 360, height: 640)

  private var timer: DispatchSourceTimer?
  private let queue = DispatchQueue(label: "headsup.scenario")

  func start() {
    guard timer == nil else { return }
    let scenario = self.scenario
    let handler = onFrame
    let started = CACurrentMediaTime()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: 1.0 / Self.frameRate)
    timer.setEventHandler {
      let now = CACurrentMediaTime()
      let detections = scenario.detections(at: now - started)
      guard let buffer = Self.render(detections) else { return }
      handler?(Frame(pixelBuffer: buffer, timestamp: now, scriptedDetections: detections))
    }
    self.timer = timer
    timer.resume()
    status = .running
  }

  func stop() {
    timer?.cancel()
    timer = nil
    status = .idle
  }

  private nonisolated static func render(_ detections: [Detection]) -> CVPixelBuffer? {
    let w = size.width, h = size.height
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    guard let buffer = pb else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    // CoreGraphics origin is bottom-left; detections use top = 0.
    ctx.setFillColor(CGColor(red: 0.55, green: 0.62, blue: 0.70, alpha: 1))
    ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
    ctx.setFillColor(CGColor(red: 0.30, green: 0.32, blue: 0.33, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
    // Draw far objects first so near ones cover them.
    for d in detections.sorted(by: { $0.area < $1.area }) {
      let x0 = (d.left + 1) / 2 * Double(w), x1 = (d.right + 1) / 2 * Double(w)
      let yTop = (1 - d.top) * Double(h), yBottom = (1 - d.bottom) * Double(h)
      let rect = CGRect(x: x0, y: yBottom, width: x1 - x0, height: yTop - yBottom)
      let color: CGColor =
        d.objectClass == .person
        ? CGColor(red: 0.85, green: 0.75, blue: 0.55, alpha: 1)
        : CGColor(red: 0.75, green: 0.35, blue: 0.30, alpha: 1)
      ctx.setFillColor(color)
      ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height) * 0.3,
                         cornerHeight: min(rect.width, rect.height) * 0.3, transform: nil))
      ctx.fillPath()
    }
    return buffer
  }
}
