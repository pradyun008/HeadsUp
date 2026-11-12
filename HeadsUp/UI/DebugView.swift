import SwiftUI

/// The judge-facing view: the live frame with what the pipeline sees drawn on top.
struct DebugView: View {
  let model: AppModel

  var body: some View {
    VStack(spacing: 12) {
      FrameOverlayView(image: model.preview, tracks: model.tracks, risk: model.risk, corridor: model.corridor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(model.status.text).font(.headline)
          Spacer()
          if model.risk.unstable {
            Text("HEAD MOVING · unstable, levels held")
              .font(.caption.bold())
              .padding(.horizontal, 8).padding(.vertical, 4)
              .background(.purple, in: Capsule())
              .foregroundStyle(.white)
          }
        }
        legend
        LevelBars(left: model.leftLevel, right: model.rightLevel)
        if let cue = model.lastCue {
          Text("Last spoken: “\(cue)”").font(.callout.bold())
        }
        Text(
          String(
            format: "Simulated band: bytes [%d, %d] · %.1f writes/s",
            model.bandPacket[0], model.bandPacket[1], model.bandWriteRate)
        )
        .font(.callout.monospacedDigit())
        if let message = model.detectorMessage {
          Text(message).font(.callout).foregroundStyle(.red)
        }
        Text(
          String(
            format: "source %.0f fps · processed %.0f fps · detect %.0f ms · dropped %d",
            model.fps, model.processedFPS, model.detectionMs, model.droppedFrames)
        )
        .font(.callout.monospacedDigit())
        Text("\(model.tracks.count) tracked · \(model.detections.count) detected · \(Int(model.frameSize.width))×\(Int(model.frameSize.height))")
          .font(.callout.monospacedDigit())
        Text("Left and right are camera-relative: the camera turns with the head.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(action: { model.isWatching ? model.stop() : model.start() }) {
        Text(model.isWatching ? "Stop" : "Start").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(.borderedProminent)
      .tint(model.isWatching ? .red : .accentColor)
    }
    .padding()
  }
}

extension DebugView {
  fileprivate var legend: some View {
    HStack(spacing: 10) {
      ForEach(
        [("not approaching", Color.gray), ("passing", .blue), ("on course", .orange), ("urgent", .red)],
        id: \.0
      ) { name, color in
        HStack(spacing: 4) {
          RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12)
          Text(name).font(.caption)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Box colours: grey not approaching, blue passing, orange on course, red urgent")
  }
}

/// The two output levels as bars. They are two learned cues, not literal directions on the wrist.
struct LevelBars: View {
  let left: Int
  let right: Int

  var body: some View {
    HStack(spacing: 16) {
      bar("Left cue", left)
      bar("Right cue", right)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Left cue level \(left) of 3. Right cue level \(right) of 3.")
  }

  private func bar(_ name: String, _ level: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(name): \(level)").font(.caption.bold().monospacedDigit())
      HStack(spacing: 3) {
        ForEach(1...3, id: \.self) { i in
          RoundedRectangle(cornerRadius: 3)
            .fill(i <= level ? Self.color(level) : Color.gray.opacity(0.25))
            .frame(height: 14)
        }
      }
    }
  }

  static func color(_ level: Int) -> Color {
    level >= 3 ? .red : level == 2 ? .orange : Color(red: 0.85, green: 0.65, blue: 0.0)
  }
}

/// A frame with detection boxes drawn over it.
struct FrameOverlayView: View {
  let image: CGImage?
  let tracks: [Track]
  var risk = RiskFrame()
  var corridor = 0.15

  var body: some View {
    ZStack {
      Rectangle().fill(.black)
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .overlay {
            Canvas { context, size in
              drawCorridor(in: &context, size: size)
              for t in tracks { draw(t, in: &context, size: size) }
            }
          }
      } else {
        Text("No video").foregroundStyle(.gray)
      }
    }
    .aspectRatio(aspect, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(image == nil ? "Camera view, no video" : "Camera view, \(tracks.count) objects tracked")
  }

  private var aspect: CGFloat {
    guard let image, image.height > 0 else { return 9.0 / 16.0 }
    return CGFloat(image.width) / CGFloat(image.height)
  }

  private func draw(_ d: Track, in context: inout GraphicsContext, size: CGSize) {
    // x: −1…+1 → 0…width. y: 0 (top)…1 (bottom) → 0…height.
    let rect = CGRect(
      x: (d.left + 1) / 2 * size.width, y: d.top * size.height,
      width: (d.right - d.left) / 2 * size.width, height: (d.bottom - d.top) * size.height)
    let assessment = risk[d.id]
    let color = Self.color(for: assessment)
    // Dashed outline = coasting: not seen this frame, position predicted from its last motion.
    context.stroke(
      Path(rect), with: .color(color),
      style: StrokeStyle(lineWidth: 3, dash: d.isCoasting ? [6, 5] : []))
    let label = Text(Self.label(for: d, assessment))
      .font(.caption.bold()).foregroundStyle(.white)
    let resolved = context.resolve(label)
    let textSize = resolved.measure(in: size)
    // Keep the label inside the frame even when the box is at an edge.
    let origin = CGPoint(
      x: max(0, min(rect.minX, size.width - textSize.width - 6)),
      y: max(0, min(rect.minY - textSize.height - 2, size.height - textSize.height - 2)))
    context.fill(
      Path(CGRect(origin: origin, size: CGSize(width: textSize.width + 6, height: textSize.height + 2))),
      with: .color(color))
    context.draw(resolved, at: CGPoint(x: origin.x + 3, y: origin.y + 1), anchor: .topLeading)
  }

  /// Dashed lines at ±corridor: the strip of the image the wearer is heading into (camera-relative).
  private func drawCorridor(in context: inout GraphicsContext, size: CGSize) {
    for edge in [-corridor, corridor] {
      let x = (edge + 1) / 2 * size.width
      var path = Path()
      path.move(to: CGPoint(x: x, y: 0))
      path.addLine(to: CGPoint(x: x, y: size.height))
      context.stroke(path, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
    }
  }

  /// grey = not approaching (or too new to judge), blue = passing, yellow/orange/red = on course by level.
  static func color(for assessment: RiskAssessment?) -> Color {
    guard let a = assessment else { return .gray }
    switch a.state {
    case .tooNew, .notApproaching: return .gray
    case .passing: return .blue
    case .onCourse:
      switch a.level {
      case 3: return .red
      case 2: return .orange
      case 1: return Color(red: 0.85, green: 0.65, blue: 0.0)
      default: return Color(red: 0.55, green: 0.5, blue: 0.2)
      }
    }
  }

  static func label(for track: Track, _ assessment: RiskAssessment?) -> String {
    var text = "#\(track.id) \(track.objectClass.rawValue)"
    if let a = assessment {
      // tau is an estimate from image growth, so it is always labelled "est."
      if let tau = a.tau { text += String(format: " · est. %.1f s", tau) }
      switch a.state {
      case .tooNew: text += " · new"
      case .notApproaching: text += " · not approaching"
      case .passing: text += " · passing"
      case .onCourse: text += " · L\(a.level)" + (a.side.map { " \($0.rawValue)" } ?? "")
      }
      if a.held { text += " · held" }
    }
    return text
  }
}
