import CoreVideo
import QuartzCore

/// One camera frame entering the pipeline.
struct Frame: @unchecked Sendable {
  let pixelBuffer: CVPixelBuffer
  /// Host-clock seconds (`CACurrentMediaTime`) when the frame reached the app.
  /// Latency is measured from this point.
  let timestamp: CFTimeInterval
}

enum FrameSourceStatus: Equatable {
  case idle
  /// Starting up; the text says what it is waiting for.
  case starting(String)
  case running
  /// Frames stopped but may come back on their own (paused, hinges closed, out of range).
  case interrupted(String)
  /// The person has to do something first (connect, grant permission).
  case needsAction(String)
  case failed(String)

  var text: String {
    switch self {
    case .idle: return "Stopped"
    case .running: return "Watching"
    case .starting(let s), .interrupted(let s), .needsAction(let s), .failed(let s): return s
    }
  }
}

/// Anything that produces frames: glasses, phone camera, video file.
@MainActor
protocol FrameSource: AnyObject {
  var displayName: String { get }
  var status: FrameSourceStatus { get }
  /// Called off the main thread, once per frame.
  var onFrame: (@Sendable (Frame) -> Void)? { get set }
  var onStatusChange: ((FrameSourceStatus) -> Void)? { get set }
  func start()
  func stop()
}

/// Frames per second over the last second of arrivals.
struct FPSMeter {
  private var times: [CFTimeInterval] = []
  private let window: CFTimeInterval

  init(window: CFTimeInterval = 1.0) { self.window = window }

  mutating func tick(at time: CFTimeInterval) -> Double {
    times.append(time)
    times.removeAll { time - $0 > window }
    guard times.count >= 2, let first = times.first, time > first else { return 0 }
    return Double(times.count - 1) / (time - first)
  }

  mutating func reset() { times.removeAll() }
}
