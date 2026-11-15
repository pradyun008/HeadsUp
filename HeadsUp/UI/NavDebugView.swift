import SwiftUI

/// The judge-facing navigation screen: the route, where the wearer is on it, what was said and
/// what is waiting to be said. It also starts the replay demo and saves walks for it.
struct NavDebugView: View {
  let model: AppModel
  @State private var walks: [SavedWalk] = []
  @State private var walkName = SavedWalk.builtIn.name
  @State private var speed = 1.0

  var body: some View {
    let nav = model.nav
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        RouteMapView(
          route: nav.destination?.route, maneuvers: nav.engine.maneuvers,
          position: nav.lastFix?.point, along: nav.along)
          .frame(height: 260)
          .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
          .accessibilityLabel("Route map")

        Text(nav.statusText).font(.title3.bold())
        if nav.isReplaying {
          Text("REPLAY · recorded positions, not live GPS")
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.indigo, in: Capsule())
            .foregroundStyle(.white)
        }

        replayButtons(nav)
        facts(nav)

        // Hazards stay visible here, so judges see both systems at once.
        LevelBars(left: model.leftLevel, right: model.rightLevel)
        if let cue = model.lastCue {
          Text("Last hazard cue: “\(cue)”").font(.callout.bold())
        }
        Text("The band is hazard-only. Directions are voice-only and wait while a hazard is spoken.")
          .font(.caption2).foregroundStyle(.secondary)

        Divider()
        replayControls(nav)
      }
      .padding()
    }
    .onAppear { reloadWalks() }
  }

  private func facts(_ nav: NavController) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      row("Next turn", nextTurnText(nav))
      row("To destination", nav.feetToDestination.map { "\($0) ft" } ?? "–")
      row("Last direction", nav.lastCue.map { "“\($0)”" } ?? "–")
      row("Waiting to speak", model.waitingSpeech.map { "“\($0)”" } ?? "nothing")
      row("Heard", nav.lastHeard.map { "“\($0)”" } ?? "–")
      row(
        "Position",
        nav.lastFix.map { fix in
          let accuracy = String(format: "±%.0f ft", fix.accuracy * Geo.feetPerMetre)
          return nav.isNavigating ? accuracy + String(format: " · %.0f ft from route", nav.offRouteMetres * Geo.feetPerMetre) : accuracy
        } ?? (nav.locationProblem ?? "no position yet"))
    }
    .font(.callout.monospacedDigit())
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
      Text(value).frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }

  private func nextTurnText(_ nav: NavController) -> String {
    guard nav.isNavigating, let next = nav.engine.nextManeuver else { return "–" }
    let m = nav.engine.maneuvers[next.index]
    var text = "\(m.direction.rawValue) in \(Geo.spokenFeet(metres: max(0, next.distance))) ft"
    if let street = m.street { text += " onto \(street)" }
    if m.crosswalk { text += " · marked crosswalk (aerial image)" }
    return text
  }

  /// Kept at the top so the demo starts with one tap, without scrolling.
  private func replayButtons(_ nav: NavController) -> some View {
    HStack(spacing: 12) {
      Button(action: {
        if let walk = walks.first(where: { $0.name == walkName }) { model.startReplayDemo(walk, speed: speed) }
      }) {
        Text("Replay demo").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(.borderedProminent)
      .accessibilityHint("Replays the saved walk and a recorded video together. Needs no GPS or network.")
      Button(action: {
        nav.stopNavigation()
        if model.isWatching { model.stop() }
      }) {
        Text("Stop").font(.title3.bold()).frame(minWidth: 80, minHeight: 44)
      }
      .buttonStyle(.bordered)
      .tint(.red)
    }
  }

  private func replayControls(_ nav: NavController) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Replay settings").font(.title3.bold()).accessibilityAddTraits(.isHeader)
      Picker("Saved walk", selection: $walkName) {
        ForEach(walks, id: \.name) { walk in
          Text("\(walk.name) · \(Int(walk.duration / 60)) min \(Int(walk.duration) % 60) s").tag(walk.name)
        }
      }
      .pickerStyle(.menu)
      Picker("Speed", selection: $speed) {
        Text("1×").tag(1.0)
        Text("2×").tag(2.0)
        Text("4×").tag(4.0)
      }
      .pickerStyle(.segmented)
      Text("Plays the video picked on the Main tab through the hazard pipeline at the same time, if there is one.")
        .font(.caption2).foregroundStyle(.secondary)

      Text("Save for replay").font(.headline)
      HStack(spacing: 12) {
        Button("Save this walk") {
          nav.saveWalk()
          reloadWalks()
        }
        Button("Save simulated walk") {
          nav.saveSimulatedWalk()
          reloadWalks()
        }
      }
      .buttonStyle(.bordered)
      Text("“Save this walk” keeps the route and the GPS positions of the walk in progress. “Save simulated walk” keeps the current route with a made-up steady walk, for a route nobody has walked.")
        .font(.caption2).foregroundStyle(.secondary)
      if let message = nav.walkMessage {
        Text(message).font(.caption)
      }
    }
  }

  private func reloadWalks() {
    walks = SavedWalk.all()
    if !walks.contains(where: { $0.name == walkName }) { walkName = walks.first?.name ?? "" }
  }
}

/// The route drawn from its own coordinates, north up. It uses no map tiles, so it works with
/// no network. Orange dots are turns; a striped dot is a turn where an aerial image showed a
/// marked crosswalk; the blue dot is the latest position; the flag is the destination.
struct RouteMapView: View {
  let route: NavRoute?
  let maneuvers: [NavigationEngine.Maneuver]
  let position: GeoPoint?
  let along: Double

  var body: some View {
    Canvas { context, size in
      guard let route, let origin = route.path.points.first, route.path.points.count >= 2 else {
        context.draw(Text("No route").foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2))
        return
      }
      // Metres east and north of the first point, for everything that is drawn.
      func metres(_ p: GeoPoint) -> CGPoint {
        let (east, north) = Geo.offset(from: origin, to: p)
        return CGPoint(x: east, y: north)
      }
      var all = route.path.points.map(metres)
      if let position { all.append(metres(position)) }
      let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
      let minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
      let padding = 28.0
      let scale = min(
        (size.width - 2 * padding) / max(maxX - minX, 1),
        (size.height - 2 * padding) / max(maxY - minY, 1))
      let offsetX = (size.width - (maxX - minX) * scale) / 2
      let offsetY = (size.height - (maxY - minY) * scale) / 2
      func screen(_ p: GeoPoint) -> CGPoint {
        let m = metres(p)
        return CGPoint(x: offsetX + (m.x - minX) * scale, y: size.height - offsetY - (m.y - minY) * scale)  // north up
      }

      // The whole route, then the part already walked on top of it.
      var line = Path()
      line.addLines(route.path.points.map(screen))
      context.stroke(line, with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
      var walked = Path()
      let walkedPoints = route.path.points.enumerated().filter { route.path.cumulative[$0.offset] < along }.map(\.element)
      walked.addLines((walkedPoints + [route.path.point(at: along)]).map(screen))
      context.stroke(walked, with: .color(.green), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))

      for maneuver in maneuvers {
        let center = screen(route.path.point(at: maneuver.along))
        let dot = Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
        context.fill(dot, with: .color(maneuver.passed ? .gray : .orange))
        if maneuver.crosswalk {
          context.stroke(dot, with: .color(.white), style: StrokeStyle(lineWidth: 3, dash: [3, 3]))
          context.draw(Text("crosswalk").font(.caption2), at: CGPoint(x: center.x, y: center.y - 16))
        }
      }

      let end = screen(route.path.point(at: route.path.length))
      context.draw(Text("⚑").font(.title2), at: CGPoint(x: end.x + 4, y: end.y - 10))

      if let position {
        let p = screen(position)
        context.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.white))
        context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.blue))
      }
      context.draw(Text("N ↑").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 18, y: 12))
    }
  }
}
