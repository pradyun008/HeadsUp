import SwiftUI

/// The judge-facing view: the live frame with what the pipeline sees drawn on top.
struct DebugView: View {
  let model: AppModel

  var body: some View {
    VStack(spacing: 12) {
      FrameOverlayView(image: model.preview, detections: model.detections)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      VStack(alignment: .leading, spacing: 4) {
        Text(model.status.text).font(.headline)
        if let message = model.detectorMessage {
          Text(message).font(.callout).foregroundStyle(.red)
        }
        Text(
          String(
            format: "source %.0f fps · processed %.0f fps · detect %.0f ms · dropped %d",
            model.fps, model.processedFPS, model.detectionMs, model.droppedFrames)
        )
        .font(.callout.monospacedDigit())
        Text("\(model.detections.count) objects · \(Int(model.frameSize.width))×\(Int(model.frameSize.height))")
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

/// A frame with detection boxes drawn over it.
struct FrameOverlayView: View {
  let image: CGImage?
  let detections: [Detection]

  var body: some View {
    ZStack {
      Rectangle().fill(.black)
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .overlay {
            Canvas { context, size in
              for d in detections { draw(d, in: &context, size: size) }
            }
          }
      } else {
        Text("No video").foregroundStyle(.gray)
      }
    }
    .aspectRatio(aspect, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(image == nil ? "Camera view, no video" : "Camera view, \(detections.count) objects detected")
  }

  private var aspect: CGFloat {
    guard let image, image.height > 0 else { return 9.0 / 16.0 }
    return CGFloat(image.width) / CGFloat(image.height)
  }

  private func draw(_ d: Detection, in context: inout GraphicsContext, size: CGSize) {
    // x: −1…+1 → 0…width. y: 0 (top)…1 (bottom) → 0…height.
    let rect = CGRect(
      x: (d.left + 1) / 2 * size.width, y: d.top * size.height,
      width: d.width / 2 * size.width, height: d.height * size.height)
    let color = Color.gray  // grey = not judged yet; risk colours arrive with the RiskEstimator
    context.stroke(Path(rect), with: .color(color), lineWidth: 3)
    let label = Text("\(d.objectClass.rawValue) \(Int(d.confidence * 100))%")
      .font(.caption.bold()).foregroundStyle(.white)
    let resolved = context.resolve(label)
    let textSize = resolved.measure(in: size)
    let origin = CGPoint(x: rect.minX, y: max(0, rect.minY - textSize.height - 2))
    context.fill(
      Path(CGRect(origin: origin, size: CGSize(width: textSize.width + 6, height: textSize.height + 2))),
      with: .color(color))
    context.draw(resolved, at: CGPoint(x: origin.x + 3, y: origin.y + 1), anchor: .topLeading)
  }
}
