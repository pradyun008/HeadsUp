import Foundation

/// One real (detected, not coasted) sighting of a tracked object.
/// x values are camera-relative, −1 (left edge) … +1 (right edge).
struct TrackObservation: Equatable, Sendable {
  var time: Double
  var left: Double
  var right: Double
  var top: Double
  var bottom: Double

  var centerX: Double { (left + right) / 2 }
  var height: Double { bottom - top }
  var area: Double { max(0, right - left) * max(0, bottom - top) }
}

/// An object followed across frames under one stable ID.
struct Track: Equatable, Sendable, Identifiable {
  let id: Int
  var objectClass: ObjectClass
  var confidence: Float
  /// Ring buffer: real sightings from the last ~1 s, oldest first. Coasted positions are not stored.
  var observations: [TrackObservation]
  /// Current box. Equals the last sighting, or a prediction while coasting.
  var left: Double
  var right: Double
  var top: Double
  var bottom: Double
  /// Time of the last real sighting.
  var lastSeen: Double
  /// True when this frame had no matching detection and the box is predicted from the last velocity.
  var isCoasting: Bool
  /// Number of real sightings since the track began.
  var hits: Int

  // Edge velocities in normalized units per second, used only for coasting and matching.
  var vLeft = 0.0
  var vRight = 0.0
  var vTop = 0.0
  var vBottom = 0.0

  var centerX: Double { (left + right) / 2 }
  /// Seconds of history covered by the stored sightings.
  var historySpan: Double {
    guard let first = observations.first, let last = observations.last else { return 0 }
    return last.time - first.time
  }
}

struct TrackerConfig: Sendable, Equatable {
  /// Minimum overlap (IoU) between a detection and a track's predicted box to count as the same object.
  var minIoU = 0.2
  /// How long a track survives with no detections, coasting on its last velocity.
  var maxCoast = 1.0
  /// How much history each track keeps.
  var historyWindow = 1.0
}

/// Simple IoU tracker (ByteTrack-lite). Matches detections to tracks greedily by overlap,
/// within the same class group, and coasts unmatched tracks for up to `maxCoast` seconds so
/// a brief occlusion or head turn does not reset the ID.
///
/// Class group: car/bus/truck count as one group and bicycle/motorcycle as another, because
/// the detector often flips between them on the same vehicle from frame to frame.
struct Tracker: Sendable {
  var config = TrackerConfig()
  private(set) var tracks: [Track] = []
  private var nextID = 1
  private var lastTime: Double?

  mutating func reset() {
    tracks = []
    nextID = 1
    lastTime = nil
  }

  /// Feed one frame's detections. Returns all live tracks, including coasting ones.
  @discardableResult
  mutating func update(_ detections: [Detection], at time: Double) -> [Track] {
    let dt = max(0, time - (lastTime ?? time))
    lastTime = time

    // 1. Predict every track forward by its last velocity.
    for i in tracks.indices {
      tracks[i].left += tracks[i].vLeft * dt
      tracks[i].right += tracks[i].vRight * dt
      tracks[i].top += tracks[i].vTop * dt
      tracks[i].bottom += tracks[i].vBottom * dt
    }

    // 2. Greedy matching: best overlaps first.
    var pairs: [(iou: Double, track: Int, detection: Int)] = []
    for (ti, track) in tracks.enumerated() {
      for (di, d) in detections.enumerated()
      where d.objectClass.spokenName == track.objectClass.spokenName {
        let iou = Self.iou(track.left, track.right, track.top, track.bottom, d.left, d.right, d.top, d.bottom)
        if iou >= config.minIoU { pairs.append((iou, ti, di)) }
      }
    }
    pairs.sort { $0.iou > $1.iou }
    var matchedTracks = Set<Int>(), matchedDetections = Set<Int>()
    for pair in pairs where !matchedTracks.contains(pair.track) && !matchedDetections.contains(pair.detection) {
      matchedTracks.insert(pair.track)
      matchedDetections.insert(pair.detection)
      apply(detections[pair.detection], to: pair.track, at: time)
    }

    // 3. Unmatched tracks coast; drop them once they have been unseen too long.
    for i in tracks.indices where !matchedTracks.contains(i) { tracks[i].isCoasting = true }
    tracks.removeAll { time - $0.lastSeen > config.maxCoast }

    // 4. Unmatched detections start new tracks.
    for (di, d) in detections.enumerated() where !matchedDetections.contains(di) {
      let obs = TrackObservation(time: time, left: d.left, right: d.right, top: d.top, bottom: d.bottom)
      tracks.append(
        Track(
          id: nextID, objectClass: d.objectClass, confidence: d.confidence, observations: [obs],
          left: d.left, right: d.right, top: d.top, bottom: d.bottom,
          lastSeen: time, isCoasting: false, hits: 1))
      nextID += 1
    }
    return tracks
  }

  private mutating func apply(_ d: Detection, to index: Int, at time: Double) {
    var track = tracks[index]
    if let last = track.observations.last, time > last.time {
      let gap = time - last.time
      // Smooth the velocity a little so one jittery box doesn't send a coasting track flying.
      let blend = track.hits > 1 ? 0.5 : 1.0
      track.vLeft += blend * ((d.left - last.left) / gap - track.vLeft)
      track.vRight += blend * ((d.right - last.right) / gap - track.vRight)
      track.vTop += blend * ((d.top - last.top) / gap - track.vTop)
      track.vBottom += blend * ((d.bottom - last.bottom) / gap - track.vBottom)
    }
    track.left = d.left
    track.right = d.right
    track.top = d.top
    track.bottom = d.bottom
    track.objectClass = d.objectClass
    track.confidence = d.confidence
    track.lastSeen = time
    track.isCoasting = false
    track.hits += 1
    track.observations.append(
      TrackObservation(time: time, left: d.left, right: d.right, top: d.top, bottom: d.bottom))
    track.observations.removeAll { time - $0.time > config.historyWindow }
    tracks[index] = track
  }

  static func iou(
    _ l1: Double, _ r1: Double, _ t1: Double, _ b1: Double,
    _ l2: Double, _ r2: Double, _ t2: Double, _ b2: Double
  ) -> Double {
    let w = min(r1, r2) - max(l1, l2), h = min(b1, b2) - max(t1, t2)
    guard w > 0, h > 0 else { return 0 }
    let inter = w * h
    let union = (r1 - l1) * (b1 - t1) + (r2 - l2) * (b2 - t2) - inter
    return union > 0 ? inter / union : 0
  }
}
