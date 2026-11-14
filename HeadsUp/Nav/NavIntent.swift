import AppIntents

/// The HeadsUp button as a system shortcut, so it can be bound to the iPhone's Action button or
/// Back Tap and pressed through a pocket. It does exactly what the on-screen button does:
/// opens the microphone for one request, or rejects the destination just announced.
struct HeadsUpButtonIntent: AppIntent {
  static var title: LocalizedStringResource = "HeadsUp button"
  static var description = IntentDescription("Speak a destination, or reject the one just announced.")
  /// Listening needs the app in front: iOS does not let a background app open the microphone.
  static var openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    // If the shortcut launched the app, wait a moment for it to finish starting.
    for _ in 0..<20 where NavController.shared == nil {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    NavController.shared?.buttonPressed()
    return .result()
  }
}

struct HeadsUpShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: HeadsUpButtonIntent(),
      phrases: ["Press the \(.applicationName) button"],
      shortTitle: "HeadsUp button",
      systemImageName: "mic.fill")
  }
}
