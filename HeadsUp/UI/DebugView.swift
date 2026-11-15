import SwiftUI

/// The judge-facing view: the live frame with what the pipeline sees drawn on top.
struct DebugView: View {
  let model: AppModel
  @State private var showFocalTest = false

  var body: some View {
    VStack(spacing: 12) {
      FrameOverlayView(
        image: model.preview, tracks: model.tracks, risk: model.risk, corridor: model.corridor,
        topTrackID: model.topTrackID)
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
        // "Is it moving?" input: what the phone thinks the wearer is doing.
        Text(Self.wearerText(model.risk.wearer)).font(.callout.monospacedDigit())
        // The step detector's input: walking when the shake is above the threshold.
        Text(
          String(
            format: "Step wobble %.3f g (walking above %.3f, stationary below %.3f)", model.stepWobble,
            MeasuredConstants.stepWobbleStart, MeasuredConstants.stepWobbleStop)
        )
        .font(.caption.monospacedDigit())
        LevelBars(left: model.leftLevel, right: model.rightLevel)
        if let cue = model.lastCue {
          Text("Last spoken: “\(cue)”").font(.callout.bold())
        }
        Text(
          String(
            format: "Simulated band: bytes [%d, %d] · %.0f writes/s",
            model.bandPacket[0], model.bandPacket[1], model.bandWriteRate)
        )
        .font(.callout.monospacedDigit())
        if let message = model.detectorMessage {
          Text(message).font(.callout).foregroundStyle(.red)
        }
        // Latency: from the frame reaching the app to the band write for it, rolling average.
        Text(String(format: "End-to-end %.0f ms · detection %.0f ms", model.endToEndMs, model.detectionMs))
          .font(.callout.bold().monospacedDigit())
          .accessibilityLabel(
            String(format: "End to end latency %.0f milliseconds. Detection %.0f milliseconds.", model.endToEndMs, model.detectionMs))
        Text(
          String(
            format: "source %.0f fps · processed %.0f fps · dropped %d · %d tracked · %d×%d",
            model.fps, model.processedFPS, model.droppedFrames, model.tracks.count,
            Int(model.frameSize.width), Int(model.frameSize.height))
        )
        .font(.caption.monospacedDigit())
        Text("Latency is measured from when a frame reaches the phone; the glasses' own Bluetooth delay is not included.")
          .font(.caption2).foregroundStyle(.secondary)
        Text("Left and right are camera-relative: the camera turns with the head.")
          .font(.caption2).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let message = model.recordingMessage {
        Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 12) {
        Button(action: { model.isWatching ? model.stop() : model.start() }) {
          Text(model.isWatching ? "Stop" : "Start").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isWatching ? .red : .accentColor)

        // Saves the incoming frames from whichever source is running to a .mov in Documents.
        Button(action: { model.toggleRecording() }) {
          Label(model.isRecording ? "Stop rec" : "Record", systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
            .font(.title3.bold()).frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(!model.isWatching)
        .accessibilityHint("Saves incoming video frames to a file for replay")
      }
      // The tape test that measures the camera's focal length, used for distance estimates.
      Button("Focal length test") { showFocalTest = true }
        .font(.callout)
        .sheet(isPresented: $showFocalTest) { FocalTestView(model: model) }
    }
    .padding()
  }
}

extension DebugView {
  fileprivate var legend: some View {
    HStack(spacing: 10) {
      ForEach(
        [("not approaching", Color.gray), ("passing", .blue), ("walking into", .teal), ("on course", .orange), ("urgent", .red)],
        id: \.0
      ) { name, color in
        HStack(spacing: 4) {
          RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12)
          Text(name).font(.caption)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Box colours: grey not approaching, blue passing, teal walking into, orange on course, red urgent")
  }

  /// "Wearer: walking 1.3 m/s (pace)" / "(default)" / "Wearer: stationary".
  static func wearerText(_ wearer: WearerMotion) -> String {
    switch wearer {
    case .stationary: return "Wearer: stationary (anything on course counts as moving)"
    case .walking(let speed, let fromPace):
      return String(format: "Wearer: walking %.1f m/s (%@)", speed, fromPace ? "pace" : "default, no pace yet")
    }
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
  /// Priority: the most urgent object (lowest tau). Drawn with a thicker outline and "TOP".
  var topTrackID: Int?

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
      style: StrokeStyle(lineWidth: d.id == topTrackID ? 6 : 3, dash: d.isCoasting ? [6, 5] : []))
    let label = Text((d.id == topTrackID ? "TOP · " : "") + Self.label(for: d, assessment))
      .font(.caption.bold()).foregroundStyle(.white)
    let resolved = context.resolve(label)
    // Measure with the frame's width as the limit, so a long label wraps instead of running
    // off the right edge (it used to be drawn as one line and clipped, hiding Z≈ and box h).
    let textSize = resolved.measure(in: CGSize(width: max(1, size.width - 6), height: size.height))
    // Keep the label inside the frame even when the box is at an edge.
    let origin = CGPoint(
      x: max(0, min(rect.minX, size.width - textSize.width - 6)),
      y: max(0, min(rect.minY - textSize.height - 2, size.height - textSize.height - 2)))
    context.fill(
      Path(CGRect(origin: origin, size: CGSize(width: textSize.width + 6, height: textSize.height + 2))),
      with: .color(color))
    context.draw(resolved, in: CGRect(origin: CGPoint(x: origin.x + 3, y: origin.y + 1), size: textSize))
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
    case .walkingInto: return .teal
    case .onCourse:
      switch a.level {
      case 3: return .red
      case 2: return .orange
      case 1: return Color(red: 0.85, green: 0.65, blue: 0.0)
      default: return Color(red: 0.55, green: 0.5, blue: 0.2)
      }
    }
  }

  /// Two lines: the judgment first, then the measurements (own speed, Z≈, box h) for the field tests.
  static func label(for track: Track, _ assessment: RiskAssessment?) -> String {
    var text = "#\(track.id) \(track.objectClass.rawValue)"
    var measurements: [String] = []
    if let a = assessment {
      // tau is an estimate from image growth, so it is always labelled "est."
      if let tau = a.tau { text += String(format: " · est. %.1f s", tau) }
      switch a.state {
      case .tooNew: text += " · new"
      case .notApproaching: text += " · not approaching"
      case .passing: text += " · passing"
      case .walkingInto: text += " · walking into"
      case .onCourse: text += " · L\(a.level)" + (a.side.map { " \($0.rawValue)" } ?? "")
      }
      if a.held { text += " · held" }
      // Level kept from going down because the box is cut off by the frame edge.
      if a.cutOffHold { text += " · cut off, level held" }
      // "Is it moving?": the object's own speed toward the wearer (estimate).
      if let own = a.ownSpeed { measurements.append(String(format: "own %.1f m/s", own)) }
      // Distance is an estimate from box height; "?" marks a box cut off by the frame edge.
      if let z = a.distance { measurements.append(String(format: "Z≈%.1f m", z) + (a.distanceReliable ? "" : "?")) }
    }
    // Suspicious size jump being checked (merge, someone in front, glitch): left out of tau.
    if track.hasCandidate { text += " · jump?" }
    // Raw box height in frame heights, for the focal-length tape test.
    measurements.append(String(format: "box h %.3f", track.bottom - track.top))
    return text + "\n" + measurements.joined(separator: " · ")
  }
}
