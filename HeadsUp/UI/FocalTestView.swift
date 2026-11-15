import SwiftUI

/// The focal-length tape test, on the phone.
///
/// A person of known height stands at 3 m, 5 m and 7 m with their WHOLE body in the frame.
/// At each distance:  focal length = box height × distance ÷ person's height,
/// where box height is a fraction of the frame height. The three results are averaged.
/// The saved value replaces the placeholder in `MeasuredConstants.focalLength`.
enum FocalTest {
  static let distances = [3.0, 5.0, 7.0]

  /// The person box to measure: the tallest person currently seen (not a coasting, remembered box).
  static func subject(in tracks: [Track]) -> Track? {
    tracks.filter { $0.objectClass == .person && !$0.isCoasting }.max { ($0.bottom - $0.top) < ($1.bottom - $1.top) }
  }

  /// Focal length in frame heights from one reading.
  static func focalLength(boxHeight: Double, distance: Double, personHeight: Double) -> Double {
    boxHeight * distance / personHeight
  }

  /// The mean of the readings, and how far apart they are as a fraction of the mean.
  /// A spread above about 10% means a reading was off (person cut off, wrong distance, not upright).
  static func average(_ readings: [Double]) -> (mean: Double, spread: Double)? {
    guard !readings.isEmpty, let low = readings.min(), let high = readings.max() else { return nil }
    let mean = readings.reduce(0, +) / Double(readings.count)
    return (mean, mean > 0 ? (high - low) / mean : 0)
  }
}

struct FocalTestView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  /// Person's height in inches. 72 in = 6 ft.
  @AppStorage("focalTestHeightInches") private var heightInches = 72
  @AppStorage(MeasuredConstants.focalLengthKey) private var savedFocalLength = 0.0
  @State private var readings: [Double: Double] = [:]
  /// Recent box heights, so a capture uses a steady average and not one jittery frame.
  @State private var recent: [Double] = []

  private var personHeight: Double { Double(heightInches) * 0.0254 }
  private var subject: Track? { FocalTest.subject(in: model.tracks) }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Stepper("Person's height: \(heightInches / 12) ft \(heightInches % 12) in", value: $heightInches, in: 48...84)
        } footer: {
          Text("Use the glasses stream at the demo resolution. The person stands upright near the middle of the picture with head and feet both visible, at a taped distance from the camera.")
        }

        Section("Live reading") {
          if let subject {
            let height = subject.bottom - subject.top
            Text(String(format: "Person box height: %.3f of the frame", height))
              .font(.title3.monospacedDigit())
            if subject.touchesFrameEdge {
              Text("The box touches the edge of the picture, so the person is cut off. Step back or tilt the camera until head and feet are both inside.")
                .foregroundStyle(.red)
            }
          } else {
            Text(model.isWatching ? "No person in view." : "Press Start on the Debug tab first.")
              .foregroundStyle(.secondary)
          }
        }

        Section("Capture") {
          ForEach(FocalTest.distances, id: \.self) { distance in
            HStack {
              Button(String(format: "Capture at %.0f m", distance)) { capture(at: distance) }
                .disabled(subject == nil || subject?.touchesFrameEdge == true || recent.count < 5)
              Spacer()
              Text(readings[distance].map { String(format: "f = %.3f", $0) } ?? "–").monospacedDigit()
            }
          }
          if let result = FocalTest.average(Array(readings.values)) {
            Text(String(format: "Average of %d: f = %.3f", readings.count, result.mean))
              .font(.title3.bold().monospacedDigit())
            if readings.count > 1 {
              Text(String(format: "Readings differ by %.0f%%.", result.spread * 100)
                + (result.spread > 0.10 ? " That is a lot: repeat the one that looks off." : " Good."))
                .foregroundStyle(result.spread > 0.10 ? .red : .secondary)
            }
            Button("Save as the focal length") { savedFocalLength = result.mean }
              .disabled(readings.count < FocalTest.distances.count)
          }
        }

        Section {
          Text(String(format: "In use now: %.3f", MeasuredConstants.focalLength)).monospacedDigit()
          if savedFocalLength > 0 {
            Text(String(format: "Saved: %.3f. It takes effect the next time the app is opened.", savedFocalLength))
            Button("Forget the saved value", role: .destructive) { savedFocalLength = 0 }
          } else {
            Text("Nothing saved. The app uses the placeholder.").foregroundStyle(.secondary)
          }
        } header: {
          Text("Focal length (in frame heights)")
        } footer: {
          Text("Distances shown in the app are estimates. Re-measure if the stream resolution changes.")
        }
      }
      .navigationTitle("Focal length test")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .onChange(of: model.frameCount) { _, _ in
        // Keep about the last second of box heights for the person in view.
        guard let subject, !subject.touchesFrameEdge else {
          recent = []
          return
        }
        recent.append(subject.bottom - subject.top)
        if recent.count > 15 { recent.removeFirst(recent.count - 15) }
      }
    }
  }

  private func capture(at distance: Double) {
    guard !recent.isEmpty else { return }
    let boxHeight = recent.reduce(0, +) / Double(recent.count)
    readings[distance] = FocalTest.focalLength(boxHeight: boxHeight, distance: distance, personHeight: personHeight)
  }
}
