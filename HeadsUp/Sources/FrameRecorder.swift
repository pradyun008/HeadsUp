import AVFoundation

/// Saves incoming frames from any source to a .mov, so real footage can be replayed later
/// through `VideoFileFrameSource` or the clip harness.
final class FrameRecorder: @unchecked Sendable {
  let url: URL
  private let queue = DispatchQueue(label: "headsup.recorder")
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var firstTime: Double?
  private var lastTime = -1.0
  private var failed = false
  private(set) var frameCount = 0

  init(url: URL) {
    self.url = url
    try? FileManager.default.removeItem(at: url)
  }

  /// A new file name in the app's Documents folder, e.g. `headsup-20261112-103700.mov`.
  static func newDocumentsURL(now: Date = Date()) -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return documents.appendingPathComponent("headsup-\(formatter.string(from: now)).mov")
  }

  /// Safe from any thread. `time` is in seconds on any steady clock.
  func append(_ buffer: CVPixelBuffer, at time: Double) {
    queue.async { [self] in
      guard !failed else { return }
      if writer == nil { start(with: buffer) }
      guard let input, let adaptor, input.isReadyForMoreMediaData else { return }  // drop, never queue
      let t = time - (firstTime ?? time)
      if firstTime == nil { firstTime = time }
      guard t > lastTime else { return }
      lastTime = t
      if adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)) {
        frameCount += 1
      } else {
        failed = true
      }
    }
  }

  private func start(with buffer: CVPixelBuffer) {
    do {
      let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: CVPixelBufferGetWidth(buffer),
          AVVideoHeightKey: CVPixelBufferGetHeight(buffer),
        ])
      input.expectsMediaDataInRealTime = true
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
      writer.add(input)
      guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
      writer.startSession(atSourceTime: .zero)
      self.writer = writer
      self.input = input
      self.adaptor = adaptor
    } catch {
      failed = true
    }
  }

  /// Closes the file. Returns its URL, or nil if nothing was written.
  func finish() async -> URL? {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        guard let writer, let input, frameCount > 0, !failed else {
          writer?.cancelWriting()
          continuation.resume(returning: nil)
          return
        }
        input.markAsFinished()
        writer.finishWriting { continuation.resume(returning: writer.status == .completed ? self.url : nil) }
      }
    }
  }
}
