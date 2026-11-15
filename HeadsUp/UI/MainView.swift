import MWDATCore
import SwiftUI

struct MainView: View {
  let model: AppModel
  let callbackError: String?
  @AppStorage(MockGlassesController.defaultsKey) private var useMockGlasses = false
  @State private var mockError: String?

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        Text(model.status.text)
          .font(.largeTitle.bold())
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .accessibilityAddTraits(.isHeader)
          .accessibilityLabel("Status: \(model.status.text)")

        if let message = callbackError ?? mockError {
          Text(message).font(.body).foregroundStyle(.red)
        }

        if model.isWatching {
          Text(String(format: "%.0f frames per second", model.fps))
            .font(.title3.monospacedDigit())
        }
        if model.isWatching {
          LevelBars(left: model.leftLevel, right: model.rightLevel)
          if let cue = model.lastCue {
            Text("Last spoken: “\(cue)”").font(.title3.bold())
          }
        }
        navigationSection
        sourcePicker

        Button(action: { model.isWatching ? model.stop() : model.start() }) {
          Text(model.isWatching ? "Stop" : "Start")
            .font(.title.bold())
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.vibrantGlass(model.isWatching ? .red : .green))
        .accessibilityHint(model.isWatching ? "Stops watching" : "Starts watching with \(model.sourceName)")

        glassesSection
        developerSection
      }
      .padding()
    }
  }

  /// Walking directions by voice. The same button is available as the "HeadsUp button" shortcut,
  /// which can be put on the iPhone's Action button or Back Tap so it works from a pocket.
  private var navigationSection: some View {
    let nav = model.nav
    let confirming = nav.state == .confirming
    return VStack(alignment: .leading, spacing: 12) {
      Text("Navigation").font(.title2.bold()).accessibilityAddTraits(.isHeader)
      Text(nav.statusText)
        .font(.title3.bold())
        .accessibilityLabel("Navigation: \(nav.statusText)")
      if nav.isNavigating, let feet = nav.feetToNextTurn {
        Text("Next turn in \(feet) feet").font(.title3.monospacedDigit())
      }
      if let problem = nav.locationProblem {
        Text(problem).font(.body).foregroundStyle(.red)
      }
      Button(action: { nav.buttonPressed() }) {
        Text(confirming ? "Not this one, next" : "Speak a destination")
          .font(.title.bold())
          .frame(maxWidth: .infinity, minHeight: 64)
      }
      .buttonStyle(.vibrantGlass(.indigo))
      .disabled(nav.state == .listening)
      .accessibilityHint(
        confirming
          ? "Rejects the place just announced and reads the next one"
          : "Opens the microphone for a few seconds. Say, for example, take me to the library. Say stop to end navigation.")
      if nav.state == .guiding || nav.state == .arrived || confirming {
        Button(action: { nav.stopNavigation() }) {
          Text("Stop navigation").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.vibrantGlass(.red))
      }
      if let heard = nav.lastHeard {
        Text("Heard: “\(heard)”").font(.body)
      }
      if let cue = nav.lastCue {
        Text("Last direction: “\(cue)”").font(.body)
      }
      // Directions are wayfinding only. They say nothing about traffic.
      Text("Directions only say where the route goes. They never say that it is safe to walk or cross.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var sourcePicker: some View {
    @Bindable var model = model
    return VStack(alignment: .leading, spacing: 8) {
      Text("Video source").font(.title2.bold()).accessibilityAddTraits(.isHeader)
      Picker("Video source", selection: $model.sourceKind) {
        ForEach(AppModel.SourceKind.allCases) { kind in
          Text(kind.label).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .controlSize(.large)
      if model.sourceKind == .videoFile {
        if model.videoFiles.isEmpty {
          Text("No video files yet. Record one on the Debug tab, or copy a .mov into HeadsUp with Finder or the Files app.")
            .font(.body)
        } else {
          Picker("File", selection: $model.videoFileName) {
            ForEach(model.videoFiles, id: \.lastPathComponent) { Text($0.lastPathComponent).tag($0.lastPathComponent) }
          }
          .pickerStyle(.menu)
          .font(.title3)
        }
      }
      if model.sourceKind == .scenario {
        Picker("Scene", selection: $model.scenarioName) {
          ForEach(Scenario.all, id: \.name) { Text($0.name).tag($0.name) }
        }
        .pickerStyle(.menu)
        .font(.title3)
        Text("A drawn scene with scripted objects, for testing without a camera.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(model.isWatching)
    .onAppear { model.refreshVideoFiles() }
  }

  private var glassesSection: some View {
    let glasses = model.glasses
    return VStack(alignment: .leading, spacing: 12) {
      Text("Glasses").font(.title2.bold()).accessibilityAddTraits(.isHeader)
      Text(registrationText(glasses))
        .font(.title3)
      if glasses.needsFirmwareUpdate {
        Button("Glasses need a firmware update") { glasses.openFirmwareUpdate() }
          .font(.title3)
      }
      if !glasses.isRegistered {
        Button(action: { glasses.connectToMetaAI() }) {
          Text("Connect glasses in Meta AI").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.vibrantGlass(.blue))
        .accessibilityHint("Opens the Meta AI app")
      } else if !useMockGlasses {
        Button("Disconnect from Meta AI") { glasses.disconnectFromMetaAI() }
          .font(.body)
      }
      // Rule 4: left/right is camera-relative.
      Text("Left and right follow the camera, which turns with your head, not your body.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func registrationText(_ glasses: GlassesFrameSource) -> String {
    switch glasses.registration {
    case .registered:
      let n = glasses.deviceCount
      return n == 0 ? "Connected to Meta AI. No glasses in range." : "Connected. \(n) glasses available."
    case .registering: return "Connecting to Meta AI…"
    case .available: return "Not connected to Meta AI."
    case .unavailable: return "Meta AI is not available on this phone."
    @unknown default: return "Unknown"
    }
  }

  private var developerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Developer").font(.title2.bold()).accessibilityAddTraits(.isHeader)
      Toggle("Use simulated glasses", isOn: $useMockGlasses)
        .font(.title3)
        .onChange(of: useMockGlasses) { _, on in
          model.stop()
          if on { mockError = MockGlassesController.enable() } else { MockGlassesController.disable() }
        }
      Text("Plays a bundled clip through Meta's mock device, with no real glasses.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
