import CoreMedia
import MWDATCamera
import MWDATCore
import Observation
import QuartzCore
import UIKit

/// Frames from Meta glasses through the Device Access Toolkit (DAT 1.0.1).
///
/// Follows Meta's iOS integration guide and CameraAccess sample:
/// register with Meta AI → device session → camera permission → camera stream.
/// The stream rides Bluetooth Classic; Meta says lower settings give better
/// image quality, so this asks for low resolution (360×640) at 15 fps.
///
/// The camera follows the wearer's head, so everything downstream that says
/// "left" or "right" is camera-relative, not body-relative.
@Observable
@MainActor
final class GlassesFrameSource: FrameSource {
  let displayName = "Glasses"
  private(set) var status: FrameSourceStatus = .idle {
    didSet { if status != oldValue { onStatusChange?(status) } }
  }
  private(set) var registration: RegistrationState
  private(set) var deviceCount = 0
  private(set) var needsFirmwareUpdate = false

  @ObservationIgnored var onFrame: (@Sendable (Frame) -> Void)?
  @ObservationIgnored var onStatusChange: ((FrameSourceStatus) -> Void)?

  static let resolution: StreamingResolution = .low
  static let frameRate: UInt = 15

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let selector: AutoDeviceSelector
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private let sessionTokens = ListenerTokenBag()
  @ObservationIgnored private let streamTokens = ListenerTokenBag()
  @ObservationIgnored private var compatibilityTokens: [AnyListenerToken] = []
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var hasStreamed = false

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.selector = AutoDeviceSelector(wearables: wearables)
    self.registration = wearables.registrationState
    tasks.append(Task { [weak self] in
      for await state in wearables.registrationStateStream() { self?.registration = state }
    })
    tasks.append(Task { [weak self] in
      for await devices in wearables.devicesStream() { self?.devicesChanged(devices) }
    })
  }

  var isRegistered: Bool { registration == .registered }

  // MARK: - Registration with Meta AI

  /// Switches to the Meta AI app so the person can connect this app to their glasses.
  func connectToMetaAI() {
    Task {
      do {
        try await wearables.startRegistration()
      } catch {
        status = .failed("Could not connect to Meta AI: \(error.localizedDescription)")
      }
    }
  }

  func disconnectFromMetaAI() {
    stop()
    Task {
      do {
        try await wearables.startUnregistration()
      } catch {
        status = .failed("Could not disconnect: \(error.localizedDescription)")
      }
    }
  }

  func openFirmwareUpdate() {
    Task { try? await wearables.openFirmwareUpdate() }
  }

  private func devicesChanged(_ devices: [DeviceIdentifier]) {
    deviceCount = devices.count
    compatibilityTokens.removeAll()
    needsFirmwareUpdate = false
    for id in devices {
      guard let device = wearables.deviceForIdentifier(id) else { continue }
      if device.compatibility() == .deviceUpdateRequired { needsFirmwareUpdate = true }
      compatibilityTokens.append(device.addCompatibilityListener { [weak self] compatibility in
        Task { @MainActor in
          if compatibility == .deviceUpdateRequired { self?.needsFirmwareUpdate = true }
        }
      })
    }
  }

  // MARK: - FrameSource

  func start() {
    guard session == nil else { return }
    guard isRegistered else {
      status = .needsAction("Glasses are not connected to HeadsUp yet")
      return
    }
    do {
      let newSession = try wearables.createSession(deviceSelector: selector)
      session = newSession
      newSession.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.sessionChanged(state) }
      }.store(in: sessionTokens)
      newSession.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.sessionFailed(error) }
      }.store(in: sessionTokens)
      status = .starting("Connecting to glasses")
      try newSession.start()
    } catch let error as DeviceSessionError {
      sessionFailed(error)
      cleanupSession()
    } catch {
      status = .failed("Glasses session: \(error.localizedDescription)")
      cleanupSession()
    }
  }

  /// Stops at once, without waiting for the glasses to confirm, so start() works again right away.
  func stop() {
    teardown()
    status = .idle
  }

  private func teardown() {
    camera?.stop()
    session?.stop()
    cleanupStream()
    cleanupSession()
  }

  // MARK: - Session

  private func sessionChanged(_ state: DeviceSessionState) {
    switch state {
    case .started:
      Task { await startCamera() }
    case .paused:
      status = .interrupted("Glasses session paused")
    case .stopped:
      let wasActive = session != nil
      cleanupStream()
      cleanupSession()
      if wasActive, status == .running || isTransient(status) {
        status = .failed("Glasses disconnected")
      }
    default:
      break
    }
  }

  private func isTransient(_ status: FrameSourceStatus) -> Bool {
    switch status {
    case .starting, .interrupted: return true
    default: return false
    }
  }

  private func sessionFailed(_ error: DeviceSessionError) {
    switch error {
    case .noEligibleDevice:
      status = .failed("No glasses found. Check they are on, unfolded and nearby")
    case .datAppOnTheGlassesUpdateRequired:
      status = .needsAction("The glasses need an update. Opening Meta AI")
      Task { try? await wearables.openDATGlassesAppUpdate() }
    case .thermalCritical, .thermalEmergency:
      status = .failed("Glasses are too hot to stream")
    case .batteryCritical, .peakPowerShutdown:
      status = .failed("Glasses battery is too low to stream")
    default:
      status = .failed("Glasses session: \(error.localizedDescription)")
    }
  }

  // MARK: - Camera stream

  private func startCamera() async {
    guard let session, camera == nil, session.state == .started else { return }
    do {
      if try await wearables.checkPermissionStatus(.camera) != .granted {
        // requestPermission switches to the Meta AI app; the status text says so first.
        status = .starting("Allow camera access in Meta AI, then come back")
        guard try await wearables.requestPermission(.camera) == .granted else {
          teardown()
          status = .needsAction("Camera permission was not granted in Meta AI")
          return
        }
      }
      let config = StreamConfiguration(
        videoCodec: .raw, resolution: Self.resolution, frameRate: Self.frameRate)
      guard let newCamera = try session.addCamera(config: config) else {
        teardown()
        status = .failed("Could not start the glasses camera")
        return
      }
      camera = newCamera
      listen(to: newCamera.stream)
      status = .starting("Starting glasses camera")
      newCamera.stream.start()
    } catch {
      teardown()
      status = .failed("Glasses camera: \(error.localizedDescription)")
    }
  }

  private func listen(to stream: MWDATCamera.Stream) {
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.streamChanged(state) }
    }.store(in: streamTokens)

    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.streamFailed(error) }
    }.store(in: streamTokens)

    // Runs on the SDK's thread. No queueing here: the detector drops frames it can't take.
    let handler = onFrame
    stream.videoFramePublisher.listen { frame in
      let now = CACurrentMediaTime()
      guard let buffer = Self.pixelBuffer(from: frame) else { return }
      handler?(Frame(pixelBuffer: buffer, timestamp: now))
    }.store(in: streamTokens)
  }

  /// Raw-codec frames normally carry a pixel buffer; fall back to the SDK's UIImage if not.
  private nonisolated static func pixelBuffer(from frame: VideoFrame) -> CVPixelBuffer? {
    if let buffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) { return buffer }
    return frame.makeUIImage()?.cgImage?.makePixelBuffer()
  }

  private func streamChanged(_ state: StreamState) {
    switch state {
    case .streaming:
      hasStreamed = true
      status = .running
    case .paused:
      status = .interrupted("Glasses stream paused")
    case .waitingForDevice:
      status = .interrupted("Waiting for glasses")
    case .stopped:
      // Ended on the glasses' side (taken off, folded, out of range): stop fully so Start works again.
      // Only after it has streamed, so a .stopped reported during start-up doesn't cancel the start.
      if hasStreamed {
        let keep = status
        teardown()
        if case .failed = keep { status = keep } else { status = .failed("Glasses stream ended") }
      }
    default:
      break
    }
  }

  private func streamFailed(_ error: StreamError) {
    switch error {
    case .permissionDenied:
      status = .needsAction("Camera permission denied. Allow it in Meta AI")
    case .deviceNotConnected, .deviceNotFound:
      status = .failed("Glasses disconnected")
    case .hingesClosed:
      status = .interrupted("Glasses are folded. Unfold them to continue")
    case .thermalHot:
      status = .failed("Glasses are too hot to stream")
    case .batteryLow, .peakPowerLimit:
      status = .failed("Glasses battery is too low to stream")
    case .timeout:
      status = .failed("Glasses did not respond in time")
    case .photoCaptureFailed:
      break
    default:
      status = .failed("Glasses stream: \(error.localizedDescription)")
    }
  }

  private func cleanupStream() {
    streamTokens.clear()
    camera = nil
    hasStreamed = false
  }

  private func cleanupSession() {
    sessionTokens.clear()
    session = nil
  }
}

extension CGImage {
  /// Copies the image into a BGRA pixel buffer.
  func makePixelBuffer() -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}
