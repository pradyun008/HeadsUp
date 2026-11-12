// Makes a small HEVC clip for DAT's mock glasses camera feed.
// Usage: swift tools/make_mock_feed.swift HeadsUp/Resources/mock_feed.mp4
// Content: a light box that grows in the middle (approaching) and a dark box that
// slides across (passing). Synthetic only; YOLO will not detect these shapes.
import AVFoundation
import CoreGraphics
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "mock_feed.mp4")
try? FileManager.default.removeItem(at: out)
let width = 360, height = 640, fps: Int32 = 15, seconds = 8

let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(
  mediaType: .video,
  outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
  ])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
  assetWriterInput: input,
  sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
  ])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let total = Int(fps) * seconds
for i in 0..<total {
  while !input.isReadyForMoreMediaData { usleep(2000) }
  var pb: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
  guard let buffer = pb else { fatalError("no pixel buffer") }
  CVPixelBufferLockBaseAddress(buffer, [])
  let ctx = CGContext(
    data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  let t = Double(i) / Double(total)
  ctx.setFillColor(CGColor(red: 0.35, green: 0.4, blue: 0.45, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  ctx.setFillColor(CGColor(red: 0.25, green: 0.3, blue: 0.3, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))  // ground (CG origin is bottom-left)
  // Passing box: slides left to right.
  ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.3, alpha: 1))
  ctx.fill(CGRect(x: -40 + t * Double(width + 40), y: 300, width: 40, height: 100))
  // Approaching box: grows in the centre.
  let w = 30 + t * 200, h = w * 2.2
  ctx.setFillColor(CGColor(red: 0.9, green: 0.85, blue: 0.7, alpha: 1))
  ctx.fill(CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
  CVPixelBufferUnlockBaseAddress(buffer, [])
  adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "wrote \(out.path)" : "failed: \(String(describing: writer.error))")
