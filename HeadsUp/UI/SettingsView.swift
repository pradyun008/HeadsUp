import SwiftUI

/// Every threshold in the pipeline, plus outputs. Changes apply at once and are saved.
struct SettingsView: View {
  @AppStorage(RouteIntelClient.defaultsKey) private var intelServer = ""
  @Bindable var model: AppModel

  var body: some View {
    NavigationStack {
      Form {
        Section("Outputs") {
          Toggle("Voice", isOn: $model.speechEnabled)
          Toggle("Band is on the other wrist", isOn: $model.swapBandChannels)
          Text("Swaps the left cue and the right cue. The two motors are cues to learn, not directions on your arm.")
            .font(.footnote).foregroundStyle(.secondary)
          Picker("Haptics output", selection: $model.hapticsOutput) {
            ForEach(AppModel.HapticsOutput.allCases) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented)
          .accessibilityLabel("Haptics output")
          Text("The band connects over Bluetooth by itself when it is switched on; the Debug tab shows its state. Phone vibration: one pulse is the left cue, two pulses the right cue, a long buzz is ahead. It repeats faster as the level rises.")
            .font(.footnote).foregroundStyle(.secondary)
          if !model.phoneHapticsSupported {
            Text("This device has no vibration motor, so Phone does nothing here.")
              .font(.footnote).foregroundStyle(.orange)
          }
        }

        Section {
          TextField("http://172.20.10.2:8000", text: $intelServer)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Route intel server address")
        } header: {
          Text("Route intel server")
        } footer: {
          Text("Address of the laptop running the HeadsUp server. It checks aerial images for marked crosswalks at each turn, once, when a route starts. Leave empty to navigate without it.")
        }
        Section("Detection") {
          slider("Minimum confidence", value: floatBinding(\.minConfidence), range: 0.1...0.9, step: 0.05, format: "%.2f")
          slider("Keep a lost track for", value: $model.config.tracker.maxCoast, range: 0.2...2, step: 0.1, format: "%.1f s")
        }

        Section {
          slider("Corridor half-width", value: $model.config.risk.corridor, range: 0.05...0.5, step: 0.01, format: "±%.2f")
          slider("Left / right boundary", value: $model.config.risk.sideThreshold, range: 0.05...0.5, step: 0.01, format: "±%.2f")
          slider("History before judging", value: $model.config.risk.minHistory, range: 0.2...1, step: 0.05, format: "%.2f s")
          slider("Level 1 below", value: $model.config.risk.tauLow, range: 3...8, step: 0.1, format: "%.1f s")
          slider("Level 2 below", value: $model.config.risk.tauHigh, range: 1.5...3.5, step: 0.1, format: "%.1f s")
          slider("Level 3 below", value: $model.config.risk.tauUrgent, range: 0.5...2, step: 0.1, format: "%.1f s")
        } header: {
          Text("Collision course")
        } footer: {
          Text("Positions run from −1 (left edge of the camera view) to +1 (right edge). The camera turns with the head. Times are estimated seconds to contact.")
        }

        Section {
          slider("Unstable above", value: $model.config.risk.unstableShiftRate, range: 0.1...2, step: 0.05, format: "%.2f /s")
          slider("Hold after a turn", value: $model.config.risk.settleTime, range: 0...1, step: 0.05, format: "%.2f s")
        } header: {
          Text("Head motion")
        } footer: {
          Text("When the whole view shifts faster than this, levels are held, not updated.")
        }

        Section("Smoothing and speech") {
          stepper("Frames to raise a level", value: $model.config.alert.upFrames, range: 1...10)
          stepper("Frames to lower a level", value: $model.config.alert.downFrames, range: 1...15)
          stepper("Speak from level", value: $model.config.alert.speechMinLevel, range: 1...3)
          slider("Repeat same object after", value: $model.config.alert.repeatInterval, range: 1...10, step: 0.5, format: "%.1f s")
        }

        Section {
          Button("Reset all thresholds to defaults", role: .destructive) { model.config = PipelineConfig() }
        }
      }
      .navigationTitle("Settings")
    }
  }

  private func floatBinding(_ keyPath: WritableKeyPath<PipelineConfig, Float>) -> Binding<Double> {
    Binding(get: { Double(model.config[keyPath: keyPath]) }, set: { model.config[keyPath: keyPath] = Float($0) })
  }

  private func slider(
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(title)
        Spacer()
        Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
      }
      Slider(value: value, in: range, step: step)
        .accessibilityLabel(title)
        .accessibilityValue(String(format: format, value.wrappedValue))
    }
  }

  private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
    Stepper(value: value, in: range) {
      HStack {
        Text(title)
        Spacer()
        Text("\(value.wrappedValue)").monospacedDigit().foregroundStyle(.secondary)
      }
    }
  }
}
