import Foundation
import Observation

/// Runs walking navigation: the button, the spoken request, the search, the confirmation and the
/// guidance cues. It only produces navigation speech. Hazard detection is separate and untouched,
/// and hazard speech always goes first (see `SpeechArbiter`).
@Observable
@MainActor
final class NavController {
  enum State: Equatable {
    case idle
    case listening
    case searching(String)
    /// A destination was announced; guidance starts unless the button is pressed.
    case confirming
    case guiding
    case arrived
  }

  /// The controller the HeadsUp button (App Intent, Action button, Back Tap) talks to.
  static weak var shared: NavController?

  private(set) var state = State.idle
  /// One line for the screen: what navigation is doing.
  private(set) var statusText = "No destination"
  private(set) var lastHeard: String?
  private(set) var lastCue: String?
  private(set) var candidates: [DestinationCandidate] = []
  private(set) var candidateIndex = 0
  private(set) var lastFix: LocationFix?
  private(set) var locationProblem: String?
  /// Feet to the next turn, for the screen.
  private(set) var feetToNextTurn: Int?
  private(set) var feetToDestination: Int?
  /// Distance walked along the route, metres. For the route map.
  private(set) var along = 0.0
  /// Distance from the route line, metres.
  private(set) var offRouteMetres = 0.0
  /// True while a saved walk is being replayed instead of live GPS.
  private(set) var isReplaying = false
  /// CoStar route intel for the current route: crosswalks seen in aerial images, arrival blurb.
  private(set) var intel: RouteIntel?
  /// One line about the intel fetch, for the debug screen.
  private(set) var intelStatus = "off (no server address in Settings)"
  /// Result of the last "save walk" action, for the screen.
  private(set) var walkMessage: String?

  /// Seconds between the spoken confirmation and the start of guidance.
  var confirmSeconds = 3.0

  /// Speaks a navigation cue. Set by the app; goes through the speech arbiter.
  @ObservationIgnored var speakCue: (NavCue) -> Void = { _ in }
  /// Speaks a plain notice ("No results for…"), at the lowest importance.
  @ObservationIgnored var speakNotice: (String) -> Void = { _ in }
  /// Cuts off navigation speech when navigation stops.
  @ObservationIgnored var stopSpeech: () -> Void = {}
  /// Told true when the microphone opens and false when it closes.
  @ObservationIgnored var listeningChanged: (Bool) -> Void = { _ in }
  /// Search and routing, replaceable in tests.
  @ObservationIgnored var search: (String, GeoPoint) async throws -> [DestinationCandidate] = DestinationSearch.find
  @ObservationIgnored var reroute: (DestinationCandidate, GeoPoint) async throws -> DestinationCandidate = DestinationSearch.reroute
  /// Route intel from the laptop server, replaceable in tests. Nil when off or failed.
  @ObservationIgnored var fetchIntel: ([(id: Int, point: GeoPoint)], String, GeoPoint?) async -> RouteIntel? = { turns, name, point in
    guard let base = RouteIntelClient.baseURL else { return nil }
    return await RouteIntelClient.fetch(turns: turns, destinationName: name, destination: point, base: base)
  }
  /// True when a server address is set, so the status line can tell "off" from "failed".
  @ObservationIgnored var intelEnabled: () -> Bool = { RouteIntelClient.baseURL != nil }
  /// Listening, replaceable in tests. Returns the transcript or nil.
  @ObservationIgnored var listen: () async -> String?
  @ObservationIgnored var cancelListen: () -> Void

  @ObservationIgnored private(set) var engine = NavigationEngine()
  @ObservationIgnored private var location: any LocationProvider
  /// The live GPS provider, kept so it can be restored after a replay.
  @ObservationIgnored private let liveLocation: any LocationProvider
  /// Positions received during the current live route, so the walk can be saved for replay.
  @ObservationIgnored private var walkFixes: [LocationFix] = []
  @ObservationIgnored private let listener = VoiceListener()
  @ObservationIgnored private var stateBeforeListening = State.idle
  @ObservationIgnored private var confirmTask: Task<Void, Never>?
  @ObservationIgnored private var confirmText: String?
  @ObservationIgnored private var rerouteTask: Task<Void, Never>?
  /// Cues produced while the microphone was open. Speaking would close the microphone, so they wait.
  @ObservationIgnored private var heldCues: [NavCue] = []

  var destination: DestinationCandidate? { candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : nil }
  var isNavigating: Bool { state == .guiding }

  init(location: (any LocationProvider)? = nil) {
    let live = location ?? CoreLocationProvider()
    self.location = live
    liveLocation = live
    let listener = self.listener
    listen = {
      if let problem = await listener.requestPermission() {
        return "\u{1}" + problem  // marks a permission message, see handle(transcript:)
      }
      return await listener.listen()
    }
    cancelListen = { listener.cancel() }
    attachLocation()
    Self.shared = self
  }

  /// Start receiving positions. Call once when the app opens, so a fix is ready before the first request.
  func activate() { location.start() }

  /// Swap live GPS for a replayed walk, or back.
  func use(location provider: any LocationProvider) {
    location.stop()
    location.onFix = nil  // a late report from the old source must not leak into the new one
    location.onProblem = nil
    locationProblem = nil
    location = provider
    attachLocation()
    provider.start()
  }

  private func attachLocation() {
    location.onFix = { [weak self] fix in self?.received(fix) }
    location.onProblem = { [weak self] problem in self?.locationProblem = problem }
  }

  // MARK: The button

  /// The one HeadsUp button.
  /// - While a destination is being confirmed: reject it and hear the next one.
  /// - Otherwise: open the microphone for one request.
  /// Navigation is ended by saying "stop", not by this button, so a stray press in a pocket
  /// cannot end a route.
  func buttonPressed() {
    switch state {
    case .confirming:
      nextCandidate()
    case .listening, .searching:
      break
    case .idle, .guiding, .arrived:
      startListening()
    }
  }

  private func startListening() {
    stateBeforeListening = state
    state = .listening
    statusText = "Listening"
    stopSpeech()  // the microphone and the navigation voice cannot share the audio route
    listeningChanged(true)
    Task {
      let transcript = await listen()
      handle(transcript: transcript)
    }
  }

  /// A hazard has to be spoken now: close the microphone and drop the request.
  func cancelListening() {
    guard state == .listening else { return }
    cancelListen()
  }

  private func handle(transcript: String?) {
    guard state == .listening else { return }
    listeningChanged(false)
    state = stateBeforeListening
    restoreStatus()
    defer { flushHeldCues() }
    guard let transcript else { return }  // cancelled, or silence: say nothing
    if transcript.hasPrefix("\u{1}") {
      speakNotice(String(transcript.dropFirst()))
      return
    }
    lastHeard = transcript
    switch VoiceCommand.parse(transcript) {
    case .none:
      speakNotice("Didn't catch that.")
    case .stop:
      if state == .guiding || state == .arrived {
        stopNavigation()
        speakNotice("Navigation stopped.")
      } else {
        speakNotice("No navigation to stop.")
      }
    case .destination(let query):
      find(query)
    }
  }

  // MARK: Search and confirmation

  private func find(_ query: String) {
    guard let fix = lastFix else {
      speakNotice(locationProblem ?? "No GPS position yet.")
      return
    }
    let previous = state
    state = .searching(query)
    statusText = "Searching for \(query)"
    Task {
      do {
        let found = try await search(query, fix.point)
        guard state == .searching(query) else { return }
        guard !found.isEmpty else {
          state = previous
          restoreStatus()
          speakNotice("No results for \(query).")
          return
        }
        // A new destination replaces any route in progress.
        engine.stop()
        candidates = found
        confirm(0)
      } catch {
        guard state == .searching(query) else { return }
        state = previous
        restoreStatus()
        speakNotice("Search failed. Check the phone's connection.")
      }
    }
  }

  private func confirm(_ index: Int) {
    candidateIndex = index
    state = .confirming
    let text = candidates[index].spokenSummary + " Starting."
    statusText = "Going to \(candidates[index].name)?"
    confirmText = text
    confirmTask?.cancel()
    // Normally the countdown starts when the sentence has been spoken (see `spoke`).
    // This backstop covers speech being switched off.
    confirmTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64((Double(text.count) * 0.08 + 4) * 1_000_000_000))
      if !Task.isCancelled { self?.startCountdown(for: text) }
    }
    speakNotice(text)
  }

  /// Tell the controller an utterance finished, so the confirmation countdown starts after the
  /// wearer has heard the whole sentence.
  func spoke(_ text: String) {
    if text == confirmText { startCountdown(for: text) }
  }

  private func startCountdown(for text: String) {
    guard state == .confirming, confirmText == text else { return }
    confirmText = nil
    confirmTask?.cancel()
    let index = candidateIndex
    confirmTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64((self?.confirmSeconds ?? 3) * 1_000_000_000))
      guard !Task.isCancelled, let self, self.state == .confirming, self.candidateIndex == index else { return }
      self.beginGuidance()
    }
  }

  private func nextCandidate() {
    confirmTask?.cancel()
    stopSpeech()
    if candidateIndex + 1 < candidates.count {
      confirm(candidateIndex + 1)
    } else {
      candidates = []
      state = .idle
      restoreStatus()
      speakNotice("No more results.")
    }
  }

  private func beginGuidance() {
    guard let destination else { return }
    engine.start(destination.route)
    walkFixes = []
    along = 0
    offRouteMetres = 0
    state = .guiding
    statusText = "Going to \(destination.name)"
    if !isReplaying { requestIntel() }
    if let fix = lastFix { received(fix) }  // speak the start cue now, not at the next GPS fix
  }

  /// Asks the laptop server about this route once, while guidance is already running.
  /// Guidance never waits for it: the answer only matters at the first advance turn notice.
  private func requestIntel() {
    intel = nil
    guard intelEnabled(), let destination else {
      intelStatus = "off (no server address in Settings)"
      return
    }
    let route = destination.route
    let turns = engine.maneuvers.enumerated().map { (id: $0.offset, point: route.path.point(at: $0.element.along)) }
    intelStatus = "asking the server about \(turns.count) turns…"
    Task { [weak self] in
      let result = await self?.fetchIntel(turns, destination.name, destination.point)
      guard let self, self.state == .guiding || self.state == .listening, self.destination?.name == destination.name else { return }
      guard let result else {
        self.intelStatus = "unavailable (navigating without it)"
        return
      }
      self.apply(result)
    }
  }

  private func apply(_ result: RouteIntel) {
    intel = result
    intelStatus = result.summary
    for turn in result.maneuvers where turn.crosswalk && engine.maneuvers.indices.contains(turn.id) {
      let along = engine.maneuvers[turn.id].along
      engine.setCrosswalk(true, nearAlong: along)
      // Also on the stored route, so a saved walk keeps the crosswalk marks.
      guard candidates.indices.contains(candidateIndex) else { continue }
      for index in candidates[candidateIndex].route.junctions.indices
      where abs(candidates[candidateIndex].route.junctions[index].along - along) <= 5 {
        candidates[candidateIndex].route.junctions[index].crosswalk = true
      }
    }
  }

  func stopNavigation() {
    confirmTask?.cancel()
    rerouteTask?.cancel()
    engine.stop()
    heldCues = []
    candidates = []
    feetToNextTurn = nil
    feetToDestination = nil
    state = .idle
    restoreStatus()
    stopSpeech()
    endReplay()
  }

  // MARK: Replay and saved walks

  /// Replays a saved walk: its route is loaded and its positions are fed in at the recorded pace
  /// (times `speed`). Needs no GPS and no network.
  func replay(_ walk: SavedWalk, speed: Double = 1) {
    stopNavigation()
    let route = walk.navRoute
    candidates = [
      DestinationCandidate(
        name: walk.destinationName, street: nil,
        point: route.destination ?? route.path.point(at: route.path.length),
        route: route, distanceMetres: route.path.length,
        minutes: Int((route.path.length / 1.35 / 60).rounded()))
    ]
    candidateIndex = 0
    isReplaying = true
    intel = walk.intel
    intelStatus = walk.intel.map { "saved with the walk · " + $0.summary } ?? "none saved with this walk"
    lastFix = nil
    use(location: GPXReplayProvider(fixes: walk.locationFixes, speed: speed))
    beginGuidance()
    statusText = "Replaying a walk to \(walk.destinationName)"
  }

  private func endReplay() {
    guard isReplaying else { return }
    isReplaying = false
    lastFix = nil
    use(location: liveLocation)
  }

  /// Saves the route being walked and the positions received so far, for replay later.
  func saveWalk() {
    guard let destination, !isReplaying, walkFixes.count >= 5 else {
      walkMessage = "Nothing to save yet. Walk a route first."
      return
    }
    var walk = SavedWalk(name: Self.walkName(destination.name), route: destination.route, fixes: walkFixes)
    walk.intel = intel
    store(walk)
  }

  /// Saves the current route with a made-up steady walk along it, so a route found at the table
  /// can be replayed without anyone having walked it.
  func saveSimulatedWalk() {
    guard let destination, !isReplaying else {
      walkMessage = "Choose a destination first."
      return
    }
    var walk = SavedWalk.simulated(name: Self.walkName(destination.name) + " simulated", route: destination.route)
    walk.intel = intel
    store(walk)
  }

  private func store(_ walk: SavedWalk) {
    do {
      let url = try walk.save()
      walkMessage = "Saved \(url.lastPathComponent)"
    } catch {
      walkMessage = "Could not save the walk: \(error.localizedDescription)"
    }
  }

  private static func walkName(_ destination: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d HHmm"
    return "\(destination) \(formatter.string(from: Date()))"
  }

  // MARK: Guidance

  private func received(_ fix: LocationFix) {
    lastFix = fix
    guard state == .guiding || (state == .listening && stateBeforeListening == .guiding) else { return }
    if !isReplaying { walkFixes.append(fix) }
    let cues = engine.update(fix)
    along = engine.along
    offRouteMetres = engine.offset
    feetToNextTurn = engine.nextManeuver.map { Geo.spokenFeet(metres: max(0, $0.distance)) }
    feetToDestination = Geo.spokenFeet(metres: engine.distanceToDestination)
    for cue in cues { say(cue) }
    switch engine.phase {
    case .needsReroute: requestReroute(from: fix)
    case .arrived:
      if state == .guiding {
        state = .arrived
        statusText = "Arrived at \(destination?.name ?? "the destination")"
        // What the building's Matterport model says about it, after the arrival cue.
        if let blurb = intel?.arrival?.blurb { speakNotice(blurb) }
        endReplay()
      }
    case .idle, .guiding: break
    }
  }

  private func say(_ cue: NavCue) {
    if state == .listening {
      heldCues.append(cue)
      return
    }
    lastCue = cue.text
    speakCue(cue)
  }

  private func flushHeldCues() {
    let held = heldCues
    heldCues = []
    // Re-word each for where the wearer is now; drop the ones that no longer apply.
    for cue in held.compactMap({ engine.refreshed($0) }) { say(cue) }
  }

  private func requestReroute(from fix: LocationFix) {
    // A replayed walk has no network to ask; its positions follow its own route anyway.
    guard rerouteTask == nil, !isReplaying, let destination else { return }
    statusText = "Rerouting"
    rerouteTask = Task { [weak self] in
      defer { self?.rerouteTask = nil }
      // Keep trying: a wearer who is off the route needs a route more than they need silence.
      for attempt in 0..<5 {
        guard let self, !Task.isCancelled, self.state == .guiding || self.state == .listening else { return }
        let from = self.lastFix?.point ?? fix.point
        if let fresh = try? await self.reroute(destination, from) {
          guard !Task.isCancelled, self.engine.phase == .needsReroute else { return }
          self.candidates[self.candidateIndex] = fresh
          self.engine.start(fresh.route)
          self.statusText = "Going to \(fresh.name)"
          if let latest = self.lastFix { self.received(latest) }
          return
        }
        try? await Task.sleep(nanoseconds: UInt64(5 + attempt * 5) * 1_000_000_000)
      }
      self?.speakNotice("Could not find a new route.")
    }
  }

  private func restoreStatus() {
    switch state {
    case .idle: statusText = "No destination"
    case .guiding: statusText = "Going to \(destination?.name ?? "the destination")"
    case .arrived: statusText = "Arrived at \(destination?.name ?? "the destination")"
    case .listening, .searching, .confirming: break
    }
  }
}
