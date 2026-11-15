import SwiftUI

/// The wristband seen from above, used by onboarding to show what each cue feels like.
///
/// Each motor pod glows in its level's color and sends out pulse rings: one ring at level 1,
/// two at level 2, three at level 3. Rings repeat at the same rates the phone-haptic fallback
/// uses (1.0, 0.6 and 0.35 s), so the picture and the felt rhythm agree. Under Reduce Motion
/// the rings hold still.
///
/// Decorative: the slide that shows it provides the spoken description.
struct WristbandIllustration: View {
  var leftLevel: Int
  var rightLevel: Int
  var showsLabels = true

  var body: some View {
    VStack(spacing: 12) {
      ZStack {
        Capsule()
          .fill(.white.opacity(0.08))
          .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
          .frame(height: 64)
          .padding(.horizontal, 20)
        HStack {
          MotorPod(level: leftLevel)
          Spacer()
          MotorPod(level: rightLevel)
        }
        // Pod frames include room for the rings, so this puts the pod centers near the strap ends.
        .padding(.horizontal, 9)
      }
      .frame(width: 312, height: 140)
      if showsLabels {
        HStack {
          Text("Left cue").opacity(leftLevel > 0 ? 1 : 0.6)
          Spacer()
          Text("Right cue").opacity(rightLevel > 0 ? 1 : 0.6)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 236)
      }
    }
    .accessibilityHidden(true)
  }

  /// Level colors match the alert levels used elsewhere: yellow low, orange high, red urgent.
  static func color(for level: Int) -> Color {
    switch level {
    case 1: return .yellow
    case 2: return .orange
    case 3: return .red
    default: return .gray
    }
  }

  /// Seconds between pulses, the same as the phone-haptic fallback.
  static func period(for level: Int) -> Double {
    [1.0, 0.6, 0.35][min(3, max(1, level)) - 1]
  }
}

private struct MotorPod: View {
  let level: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let podSize: CGFloat = 48
  private let ringStep: CGFloat = 26

  var body: some View {
    let color = WristbandIllustration.color(for: level)
    TimelineView(.animation(paused: reduceMotion || level == 0)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      let period = WristbandIllustration.period(for: level)
      let phase = reduceMotion ? 0.6 : (t / period).truncatingRemainder(dividingBy: 1)
      ZStack {
        ForEach(0..<max(level, 0), id: \.self) { i in
          // Rings are staggered across one period so there is always one leaving the pod.
          let ringPhase = reduceMotion ? 1 : (phase + Double(i) / Double(level)).truncatingRemainder(dividingBy: 1)
          Circle()
            .stroke(color.opacity(0.8 - Double(i) * 0.15), lineWidth: 2)
            .frame(width: podSize + ringStep * CGFloat(i + 1), height: podSize + ringStep * CGFloat(i + 1))
            .scaleEffect(0.7 + 0.3 * ringPhase)
            .opacity(reduceMotion ? 0.7 - Double(i) * 0.15 : 1 - ringPhase)
        }
        Circle()
          .fill(level == 0 ? Color.white.opacity(0.16) : color)
          .overlay(Circle().strokeBorder(.white.opacity(level == 0 ? 0.3 : 0), lineWidth: 1))
          .frame(width: podSize, height: podSize)
          // The pod brightens at the start of each pulse.
          .brightness(level > 0 && phase < 0.3 ? 0.12 : 0)
          .shadow(color: level == 0 ? .clear : color.opacity(0.35 + 0.2 * Double(level)), radius: CGFloat(10 + 8 * level))
      }
      .frame(width: podSize + ringStep * 3, height: podSize + ringStep * 3)
    }
  }
}
