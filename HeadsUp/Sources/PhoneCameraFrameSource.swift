import AVFoundation
import QuartzCore

/// The iPhone's rear camera, in portrait, as a stand-in for the glasses camera.
/// Fallback if the glasses stream fails, and handy for desk testing.
/// Left/right are relative to this camera, wherever the phone is pointing.
@MainActor
final class PhoneCameraFrameSource: NSObject, FrameSource {
  let displayName = "Phone camera"
  private(set) var status: FrameSourceStatus = .idle {
    didSet { if status != oldValue { onStatusChange?(status) } }
  }
  var onFrame: (@Sendable (Frame) -> Void)?
  var onStatusChange: ((FrameSourceStatus) -> Void)?

  /// Matches the glasses stream rate so timing behaves the same.
  static let frameRate: Int32 = 15

  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "headsup.phonecamera")
  private let delegate = SampleDelegate()
  private var configured = false
  private var wanted = false

  func start() {
    wanted = true
    status = .starting("Starting phone camera")
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      begin()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        Task { @MainActor in
          guard self.wanted else { return }
          if granted { self.begin() } else { self.denied() }
        }
      }
    default:
      denied()
    }
  }

  private func denied() {
    wanted = false
    status = .needsAction("Camera access is off. Turn it on in Settings")
  }

  private func begin() {
    delegate.handler = onFrame
    if !configured {
      guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
        let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
      else {
        wanted = false
        status = .failed("This device has no rear camera")
        return
      }
      session.beginConfiguration()
      session.sessionPreset = .hd1280x720
      session.addInput(input)
      let output = AVCaptureVideoDataOutput()
      output.alwaysDiscardsLateVideoFrames = true  // never queue frames
      output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
      output.setSampleBufferDelegate(delegate, queue: queue)
      if session.canAddOutput(output) { session.addOutput(output) }
      if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90  // portrait, like the glasses
      }
      session.commitConfiguration()
      if (try? device.lockForConfiguration()) != nil {
        let duration = CMTime(value: 1, timescale: Self.frameRate)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
      }
      configured = true
    }
    let session = self.session
    queue.async {
      session.startRunning()
      Task { @MainActor in if self.wanted { self.status = .running } }
    }
  }

  func stop() {
    wanted = false
    let session = self.session
    queue.async { if session.isRunning { session.stopRunning() } }
    status = .idle
  }
}

private final class SampleDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  var handler: (@Sendable (Frame) -> Void)?

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    handler?(Frame(pixelBuffer: buffer, timestamp: CACurrentMediaTime()))
  }
}
