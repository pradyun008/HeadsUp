import MWDATCore
import SwiftUI

@main
struct HeadsUpApp: App {
  /// Nil when the Meta SDK failed to start (Wearables.shared traps if configure() failed).
  @State private var model: AppModel?
  @State private var callbackError: String?
  @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

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
        if !hasCompletedOnboarding {
          // First run only. To see it again, launch with `-hasCompletedOnboarding NO`.
          OnboardingView(onFinish: finishOnboarding)
            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 1.04))))
        } else if let model {
          TabView {
            MainView(model: model, callbackError: callbackError)
              .tabItem { Label("Main", systemImage: "eye") }
            DebugView(model: model)
              .tabItem { Label("Debug", systemImage: "viewfinder") }
            NavDebugView(model: model)
              .tabItem { Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            SettingsView(model: model)
              .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
          }
          .transition(.opacity.combined(with: .offset(y: 8)))
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

  /// Hands off from onboarding to the app: the slides fade and grow slightly while the tabs fade
  /// up into place (0.55 s, cubic-bezier 0.65, 0, 0.35, 1), or a short crossfade under Reduce Motion.
  private func finishOnboarding() {
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .timingCurve(0.65, 0, 0.35, 1, duration: 0.55)) {
      hasCompletedOnboarding = true
    }
  }
}
