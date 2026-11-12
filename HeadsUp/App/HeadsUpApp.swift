import MWDATCore
import SwiftUI

@main
struct HeadsUpApp: App {
  /// Nil when the Meta SDK failed to start (Wearables.shared traps if configure() failed).
  @State private var model: AppModel?
  @State private var callbackError: String?

  init() {
    do {
      try Wearables.configure()
    } catch {
      NSLog("[HeadsUp] Wearables.configure failed: \(error)")
      _model = State(wrappedValue: nil)
      return
    }
    if UserDefaults.standard.bool(forKey: MockGlassesController.defaultsKey) {
      if let message = MockGlassesController.enable() { NSLog("[HeadsUp] \(message)") }
    }
    _model = State(wrappedValue: AppModel(glasses: GlassesFrameSource(wearables: Wearables.shared)))
  }

  var body: some Scene {
    WindowGroup {
      Group {
        if let model {
          MainView(model: model, callbackError: callbackError)
        } else {
          Text("The Meta glasses SDK failed to start. Check the app's signing and Info.plist.")
            .font(.title2).padding()
        }
      }
        .onOpenURL { url in
          // Meta AI calls back here after registration and permission prompts.
          guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
          else { return }
          Task {
            do {
              _ = try await Wearables.shared.handleUrl(url)
              callbackError = nil
            } catch {
              callbackError = "Meta AI callback failed: \(error.localizedDescription)"
            }
          }
        }
    }
  }
}
