import AVFoundation
import QuartzCore

/// Reads upright BGRA frames from a video file, one at a time, in order.
/// Applies the file's rotation, so a portrait phone recording comes out portrait.
final class VideoFrameReader {
  private let reader: AVAssetReader
  private let output: AVAssetReaderOutput
  let nominalFrameRate: Double

  init(url: URL) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw NSError(domain: "HeadsUp", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video in \(url.lastPathComponent)"])
    }
    nominalFrameRate = Double(try await track.load(.nominalFrameRate))
    reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let composed = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
    composed.videoComposition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
    composed.alwaysCopiesSampleData = false
    output = composed
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? NSError(domain: "HeadsUp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot read \(url.lastPathComponent)"])
    }
  }

  /// The next frame and its time in the file (seconds), or nil at the end.
  func next() -> (buffer: CVPixelBuffer, time: Double)? {
    while let sample = output.copyNextSampleBuffer() {
      if let buffer = CMSampleBufferGetImageBuffer(sample) {
        return (buffer, CMSampleBufferGetPresentationTimeStamp(sample).seconds)
      }
    }
    return nil
  }
}

/// Plays a recorded video at its native frame rate, looping. For repeatable testing and as a
/// demo backup. Left/right are relative to the camera that recorded the clip.
@MainActor
final class VideoFileFrameSource: FrameSource {
  let displayName = "Video file"
  private(set) var status: FrameSourceStatus = .idle {
    didSet { if status != oldValue { onStatusChange?(status) } }
  }
  var onFrame: (@Sendable (Frame) -> Void)?
  var onStatusChange: ((FrameSourceStatus) -> Void)?
  var url: URL?

  private var task: Task<Void, Never>?

  func start() {
    guard task == nil else { return }
    guard let url else {
      status = .needsAction("No video file chosen")
      return
    }
    status = .starting("Opening \(url.lastPathComponent)")
    let handler = onFrame
    task = Task.detached(priority: .userInitiated) { [weak self] in
      do {
        while !Task.isCancelled {
          let reader = try await VideoFrameReader(url: url)
          await self?.setStatus(.running)
          let began = CACurrentMediaTime()
          var first: Double?
          var count = 0
          while !Task.isCancelled, let (buffer, time) = reader.next() {
            if first == nil { first = time }
            // Wait until this frame is due, so the clip plays at its recorded speed.
            let due = began + (time - (first ?? time))
            let wait = due - CACurrentMediaTime()
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            handler?(Frame(pixelBuffer: buffer, timestamp: CACurrentMediaTime()))
            count += 1
          }
          if count == 0 { throw NSError(domain: "HeadsUp", code: 3, userInfo: [NSLocalizedDescriptionKey: "No frames in \(url.lastPathComponent)"]) }
          // Loop: pause briefly so tracks from the end do not join the start.
          try await Task.sleep(nanoseconds: 1_200_000_000)
        }
      } catch is CancellationError {
      } catch {
        await self?.fail("Video file: \(error.localizedDescription)")
      }
    }
  }

  private func setStatus(_ new: FrameSourceStatus) { if task != nil { status = new } }

  private func fail(_ message: String) {
    task = nil
    status = .failed(message)
  }

  func stop() {
    task?.cancel()
    task = nil
    status = .idle
  }
}
