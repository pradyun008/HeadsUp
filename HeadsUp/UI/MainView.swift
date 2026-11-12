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

        preview

        Button(action: { model.isWatching ? model.stop() : model.start() }) {
          Text(model.isWatching ? "Stop" : "Start")
            .font(.title.bold())
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isWatching ? .red : .accentColor)
        .accessibilityHint(model.isWatching ? "Stops watching" : "Starts watching with \(model.sourceName)")

        glassesSection
        developerSection
      }
      .padding()
    }
  }

  private var preview: some View {
    ZStack(alignment: .topLeading) {
      Rectangle().fill(.black)
      if let image = model.preview {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
      } else {
        Text("No video").foregroundStyle(.gray).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if model.isWatching {
        Text(String(format: "%.0f fps  %d×%d", model.fps, Int(model.frameSize.width), Int(model.frameSize.height)))
          .font(.callout.monospacedDigit().bold())
          .padding(6)
          .background(.black.opacity(0.6))
          .foregroundStyle(.white)
          .padding(8)
      }
    }
    .aspectRatio(9.0 / 16.0, contentMode: .fit)
    .frame(maxHeight: 420)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      model.isWatching
        ? "Camera view, \(Int(model.fps)) frames per second"
        : "Camera view, no video")
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
        .buttonStyle(.bordered)
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
