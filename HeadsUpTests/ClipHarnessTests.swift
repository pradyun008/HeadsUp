import CoreGraphics
import ImageIO
import XCTest
@testable import HeadsUp

final class ClipHarnessTests: XCTestCase {
  private func samplePhoto() throws -> CGImage {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "bus", withExtension: "jpg"))
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }

  /// A 360×640 frame showing `rect` of the photo, like a camera view of it.
  private func frame(_ image: CGImage, showing rect: CGRect) -> CVPixelBuffer {
    let ctx = CGContext(
      data: nil, width: 360, height: 640, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image.cropping(to: rect)!, in: CGRect(x: 0, y: 0, width: 360, height: 640))
    return ctx.makeImage()!.makePixelBuffer()!
  }

  /// Records a clip with FrameRecorder that zooms in on one person in the sample photo (they
  /// grow in the middle of the view, as if walking straight at the camera), then replays the
  /// file through the full pipeline with the real detector.
  func testRecordedZoomClipIsJudgedOnCourse() async throws {
    let image = try samplePhoto()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-\(UUID().uuidString).mov")
    let recorder = FrameRecorder(url: url)
    // Person standing at about x 220–345, y 400–860 in the 810×1080 photo; centre ≈ (283, 630).
    let frames = 45
    for i in 0..<frames {
      // Constant closing speed: view height shrinks like distance does. Contact would be at 4.5 s.
      let t = Double(i) / 15
      let h = 1060.0 * (4.5 - t) / 4.5
      let w = h * 9 / 16
      let rect = CGRect(x: max(0, 283 - w / 2), y: max(0, min(1080 - h, 630 - h / 2)), width: w, height: h)
      recorder.append(frame(image, showing: rect), at: t)
      // The recorder drops frames it cannot take yet (it never queues), so feed it at a live-like pace.
      try await Task.sleep(nanoseconds: 40_000_000)
    }
    let saved = await recorder.finish()
    XCTAssertEqual(saved, url)
    XCTAssertEqual(recorder.frameCount, frames)

    let logs = try await ClipHarness.run(url: url, detector: try YOLODetector())
    print(ClipHarness.text(logs))
    XCTAssertEqual(logs.count, frames)
    XCTAssertEqual(logs.last!.time, Double(frames - 1) / 15, accuracy: 0.05)
    // The centred person is judged on course and the output level rises.
    let onCourse = logs.flatMap(\.tracks).filter { $0.objectClass == .person && $0.assessment?.state == .onCourse }
    XCTAssertFalse(onCourse.isEmpty)
    XCTAssertGreaterThanOrEqual(logs.map { max($0.leftLevel, $0.rightLevel) }.max() ?? 0, 1)
    try? FileManager.default.removeItem(at: url)
  }

  /// Runs every clip in the repo's `clips/` folder and writes `<clip>.log.txt` beside it.
  /// Put real recordings there (someone walking past, someone walking toward the camera).
  func testLogClipsFolder() async throws {
    let clips = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("clips")
    let files = ((try? FileManager.default.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil)) ?? [])
      .filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
    try XCTSkipIf(files.isEmpty, "No clips in \(clips.path)")
    let detector = try YOLODetector()
    for file in files {
      let logs = try await ClipHarness.run(url: file, detector: detector)
      let text = ClipHarness.text(logs)
      try text.write(to: file.appendingPathExtension("log.txt"), atomically: true, encoding: .utf8)
      let cues = logs.flatMap(\.cues)
      print("CLIP \(file.lastPathComponent): \(logs.count) frames, max level \(logs.map { max($0.leftLevel, $0.rightLevel) }.max() ?? 0), spoken \(cues)")
    }
  }
}
