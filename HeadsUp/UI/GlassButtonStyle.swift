import SwiftUI

/// A colorful Liquid Glass capsule for the app's main actions.
///
/// iOS 26 draws real glass tinted with `tint`. Earlier systems get a solid tinted capsule with a
/// thin lit edge, and Reduce Transparency gets a plain solid fill.
///
/// The label color is picked per tint (black or white, whichever contrasts more with the
/// resolved tint in the current appearance). Bright tints such as mint, orange and teal only
/// reach readable contrast with black text; deep tints in Light mode need white.
struct VibrantGlassButtonStyle: ButtonStyle {
  var tint: Color

  @Environment(\.self) private var environment
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Self.labelColor(on: tint, in: environment))
      .padding(.horizontal, 16)
      .background { background }
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.45)
      .animation(.spring(response: 0.28, dampingFraction: 0.9), value: configuration.isPressed)
  }

  @ViewBuilder private var background: some View {
    if reduceTransparency {
      Capsule().fill(tint)
    } else if #available(iOS 26.0, *) {
      // Glass sits behind the label, not on it, so the button itself still receives the tap.
      Capsule().fill(.clear).glassEffect(.regular.tint(tint), in: Capsule())
    } else {
      Capsule()
        .fill(tint)
        .overlay(
          Capsule().strokeBorder(
            LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
            lineWidth: 0.75)
        )
        .shadow(color: tint.opacity(0.35), radius: 12, y: 6)
    }
  }

  /// Black or white, whichever has the higher WCAG contrast ratio against `tint`.
  static func labelColor(on tint: Color, in environment: EnvironmentValues) -> Color {
    let c = tint.resolve(in: environment)
    func linear(_ v: Float) -> Double {
      let v = Double(v)
      return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    // Color.Resolved components are already gamma-encoded sRGB.
    let luminance = 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    let onBlack = (luminance + 0.05) / 0.05
    let onWhite = 1.05 / (luminance + 0.05)
    return onBlack >= onWhite ? .black : .white
  }
}

extension ButtonStyle where Self == VibrantGlassButtonStyle {
  /// A colorful Liquid Glass capsule. See `VibrantGlassButtonStyle`.
  static func vibrantGlass(_ tint: Color) -> VibrantGlassButtonStyle { VibrantGlassButtonStyle(tint: tint) }
}
