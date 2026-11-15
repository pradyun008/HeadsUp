import SwiftUI

/// First-run onboarding: what HeadsUp is, what the two band cues feel like, then into the app.
///
/// Written for a caretaker setting the app up, or for a wearer listening with VoiceOver, so every
/// slide also works when only heard. Rule 1 holds throughout: nothing here says anything is safe
/// or tells the wearer what to do. Rule 4: left and right are described as the camera sees them.
///
/// The slides only show the cues. They do not drive the band or the phone haptics, which belong
/// to the hazard loop. Design: `.plans/headsup-onboarding-spec.md`.
struct OnboardingView: View {
  /// Called when the wearer taps "Get started". The caller animates the hand-off into the app.
  var onFinish: () -> Void

  @State private var step = 0
  @AccessibilityFocusState private var titleFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var slide: Slide { Slide.all[step] }
  private var isLast: Bool { step == Slide.all.count - 1 }

  var body: some View {
    ZStack {
      GlowBackground(glows: slide.glows)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.6), value: step)

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          hero
            .frame(maxWidth: .infinity)
            .frame(minHeight: 300)
            .padding(.top, 72)
          textBlock
            .padding(.top, 28)
        }
        .padding(.horizontal, 24)
        .id(step)
        .transition(slideTransition)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .overlay(alignment: .topLeading) { backButton }
    .safeAreaInset(edge: .bottom) { bottomBar }
    .preferredColorScheme(.dark)
    .animation(stepAnimation, value: step)
    .onChange(of: step) {
      // Move VoiceOver to the new slide's title once the transition has settled.
      Task {
        try? await Task.sleep(for: .milliseconds(500))
        titleFocused = true
      }
    }
  }

  // MARK: Pieces

  @ViewBuilder private var hero: some View {
    switch slide.hero {
    case .brand(let showsBand, let tint):
      BrandHero(showsBand: showsBand, tint: tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsBand ? "HeadsUp glasses and wristband" : "HeadsUp glasses")
    case .band(let left, let right):
      WristbandIllustration(leftLevel: left, rightLevel: right)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(left > 0 ? "Wristband. Left cue buzzing." : "Wristband. Right cue buzzing.")
    case .intensity:
      VStack(spacing: 2) {
        ForEach(1...3, id: \.self) { level in
          VStack(spacing: 0) {
            WristbandIllustration(leftLevel: level, rightLevel: level, showsLabels: false)
              .scaleEffect(0.78)
              .frame(height: 112)
            Text(["Low", "High", "Urgent"][level - 1])
              .font(.footnote.weight(.semibold))
              .foregroundStyle(WristbandIllustration.color(for: level))
          }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Wristband, both cues buzzing. Low, slow pulses. High, faster pulses. Urgent, fastest pulses.")
    }
  }

  private var textBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let kicker = slide.kicker {
        Text(kicker)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(slide.accent)
      }
      Text(slide.title)
        .font(.largeTitle.bold())
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($titleFocused)
      Text(slide.body)
        .font(.body)
        .foregroundStyle(.white.opacity(0.75))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var backButton: some View {
    if step > 0 {
      Button(action: { step -= 1 }) {
        Image(systemName: "chevron.backward")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 48, height: 48)
          .background { backDisc }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Back")
      .padding(.leading, 16)
      .padding(.top, 4)
    }
  }

  @ViewBuilder private var backDisc: some View {
    if #available(iOS 26.0, *) {
      Circle().fill(.clear).glassEffect(.regular, in: Circle())
    } else {
      Circle().fill(.ultraThinMaterial)
    }
  }

  private var bottomBar: some View {
    VStack(spacing: 18) {
      PageDots(count: Slide.all.count, current: step)
      Button(action: advance) {
        Text(slide.button)
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 56)
      }
      .buttonStyle(.vibrantGlass(slide.accent))
      .accessibilityHint(isLast ? "Opens HeadsUp" : "Next page")
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 8)
  }

  private func advance() {
    if isLast { onFinish() } else { step += 1 }
  }

  // MARK: Motion

  /// Text rises 8 pt and fades in a beat after the old slide fades out (cubic-bezier 0.22, 1, 0.36, 1).
  private var slideTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .opacity.combined(with: .offset(y: 8)).animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.45).delay(0.16)),
      removal: .opacity.animation(.easeOut(duration: 0.18)))
  }

  private var stepAnimation: Animation {
    reduceMotion ? .easeInOut(duration: 0.15) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.45)
  }
}

// MARK: - Content

private struct Slide {
  enum Hero {
    case brand(showsBand: Bool, tint: Color)
    case band(left: Int, right: Int)
    case intensity
  }

  var kicker: String?
  var title: String
  var body: String
  var button: String
  var accent: Color
  var hero: Hero
  var glows: [Glow]

  static let all: [Slide] = [
    Slide(
      kicker: "WELCOME",
      title: "Meet HeadsUp",
      body: "An awareness aid for blind and low-vision pedestrians. If you're setting it up for someone you care for, read along. Every screen also works with VoiceOver.",
      button: "Continue", accent: .indigo, hero: .brand(showsBand: true, tint: .indigo),
      glows: [Glow(.indigo, 0.15, 0.12, 0.62, 0.32, 0.85), Glow(.purple, 0.9, 0.08, 0.55, 0.28, 0.7), Glow(.teal, 0.55, 0.42, 0.6, 0.26, 0.55)]),
    Slide(
      kicker: "THE WRISTBAND · 1 OF 3",
      title: "Left cue",
      body: "Something heading toward you on the left of the camera's view buzzes the left cue. The camera turns with your head.",
      button: "Continue", accent: .orange, hero: .band(left: 2, right: 0),
      glows: [Glow(.orange, 0.08, 0.3, 0.6, 0.3, 0.8), Glow(.indigo, 0.95, 0.08, 0.55, 0.28, 0.55)]),
    Slide(
      kicker: "THE WRISTBAND · 2 OF 3",
      title: "Right cue",
      body: "Something heading toward you on the right of the camera's view buzzes the right cue.",
      button: "Continue", accent: .orange, hero: .band(left: 0, right: 2),
      glows: [Glow(.orange, 0.92, 0.3, 0.6, 0.3, 0.8), Glow(.indigo, 0.05, 0.08, 0.55, 0.28, 0.55)]),
    Slide(
      kicker: "THE WRISTBAND · 3 OF 3",
      title: "Both cues at once",
      body: "Something straight ahead buzzes both cues. The closer it gets, the stronger and faster the buzz.",
      button: "Continue", accent: .red, hero: .intensity,
      glows: [Glow(.yellow, 0.15, 0.1, 0.5, 0.22, 0.45), Glow(.orange, 0.85, 0.2, 0.55, 0.26, 0.6), Glow(.red, 0.5, 0.42, 0.65, 0.24, 0.6)]),
    Slide(
      kicker: nil,
      title: "HeadsUp tells you what's around you.",
      body: "You decide what to do.",
      button: "Get started", accent: .mint, hero: .brand(showsBand: false, tint: .mint),
      glows: [Glow(.mint, 0.15, 0.14, 0.6, 0.3, 0.75), Glow(.blue, 0.9, 0.12, 0.55, 0.28, 0.7), Glow(.indigo, 0.5, 0.42, 0.6, 0.25, 0.55)]),
  ]
}

/// One soft radial glow: center and radii as fractions of the screen, peak opacity.
private struct Glow {
  var color: Color
  var x: Double, y: Double, rx: Double, ry: Double, opacity: Double
  init(_ color: Color, _ x: Double, _ y: Double, _ rx: Double, _ ry: Double, _ opacity: Double) {
    self.color = color; self.x = x; self.y = y; self.rx = rx; self.ry = ry; self.opacity = opacity
  }
}

// MARK: - Views

/// Black base with colored glows in the top half, so text in the lower half stays high-contrast.
/// The glows drift slowly; under Reduce Motion they hold still.
private struct GlowBackground: View {
  var glows: [Glow]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geo in
      TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
        let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
        ZStack {
          Color.black
          ForEach(Array(glows.enumerated()), id: \.offset) { i, glow in
            GlowLayer(glow: glow, index: i, time: t, size: geo.size)
          }
        }
      }
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
  }
}

/// One glow, drifting about 6% and breathing about 8% over 20 to 26 s.
private struct GlowLayer: View {
  var glow: Glow
  var index: Int
  var time: Double
  var size: CGSize

  var body: some View {
    let i = Double(index)
    let drift: Double = 0.06 * sin(time / (20 + i * 3) * 2 * Double.pi + i)
    let breathe: Double = 1 + 0.08 * sin(time / 26 * 2 * Double.pi + i * 1.7)
    let gradient = EllipticalGradient(
      colors: [glow.color.opacity(glow.opacity), glow.color.opacity(0)],
      center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
    return Rectangle()
      .fill(gradient)
      .frame(width: size.width * glow.rx * 2, height: size.height * glow.ry * 2)
      .scaleEffect(breathe)
      .position(x: size.width * (glow.x + drift), y: size.height * (glow.y + drift * 0.5))
  }
}

/// The glasses on a tinted glass disc, with the band beside it on the first slide.
private struct BrandHero: View {
  var showsBand: Bool
  var tint: Color
  @Environment(\.self) private var environment

  var body: some View {
    ZStack {
      disc(symbol: "eyeglasses", tint: tint, size: 164, symbolSize: 64)
      if showsBand {
        disc(symbol: "dot.radiowaves.left.and.right", tint: .teal, size: 82, symbolSize: 32)
          .offset(x: 78, y: 68)
      }
    }
    .frame(width: 280, height: 280)
  }

  private func disc(symbol: String, tint: Color, size: CGFloat, symbolSize: CGFloat) -> some View {
    Image(systemName: symbol)
      .font(.system(size: symbolSize, weight: .semibold))
      .foregroundStyle(VibrantGlassButtonStyle.labelColor(on: tint, in: environment))
      .frame(width: size, height: size)
      .background {
        if #available(iOS 26.0, *) {
          Circle().fill(.clear).glassEffect(.regular.tint(tint), in: Circle())
        } else {
          Circle().fill(tint)
        }
      }
      .shadow(color: tint.opacity(0.45), radius: 24)
  }
}

/// Five dots for the five slides. VoiceOver hears "Page 2 of 5" instead of the dots.
private struct PageDots: View {
  var count: Int
  var current: Int

  var body: some View {
    HStack(spacing: 9) {
      ForEach(0..<count, id: \.self) { i in
        Circle()
          .fill(.white.opacity(i == current ? 1 : 0.3))
          .frame(width: 7, height: 7)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Page \(current + 1) of \(count)")
  }
}
