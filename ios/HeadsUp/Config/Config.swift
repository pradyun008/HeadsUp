/// Central configuration from DESIGN.md §10. Units are seconds unless noted.
/// Camera calibration is deliberately absent until measured (§11.0).
enum Config {
    static let movableClasses = ["person", "bicycle", "car", "motorcycle", "bus", "truck", "dog"]
    static let detectionConfidenceMin = 0.35
    static let iouMatchMin = 0.3
    static let trackMaxMissedFrames = 8
    static let trackMinHitsBeforeAlert = 3
    static let ttcWindow = 0.5
    static let kalmanMeasNoiseL = 0.03
    static let kalmanProcNoiseL = 0.5
    static let kalmanMeasNoiseX = 0.01
    static let kalmanProcNoiseX = 0.3
    static let ttcMinRate = 0.05
    static let confidenceDisagreeMax = 0.5
    static let courseMarginDefault = 1.0
    static let courseMarginMin = 0.6
    static let cameraHFOV: Double? = nil // degrees; measured, never guessed
    static let personHeight = 1.7 // meters
    static let carWidth = 1.8 // meters
    static let approachSpeedMin = 0.7 // m/s
    static let approachConsecutiveFrames = 4
    static let standingNoStepTime = 1.5
    static let tauDotAccelerating = -1.2
    static let tauDotBraking = -0.5
    static let leadTimeDefault = 1.5
    static let leadTimeFloor = 1.5
    static let leadTimeCeiling = 4.0
    static let level2Offset = 0.5
    static let level1Offset = 2.5
    static let aheadZone = 0.15
    static let bandWriteInterval = 0.2
    static let bandWatchdog = 600 // milliseconds; mirrored in firmware config.h
    static let reactionWindow = 3.0
    static let stopNoStepTime = 0.8
    static let headTurnShiftMin = 0.08
    static let safetyMargin = 0.8
    static let nearMissTTC = 1.0
    static let busyObjectCount = 3
    static let voiceMinInterval = 2.0
    static let cloudTimeoutMuse = 4.0
    static let cloudTimeoutAgent = 20.0
    static let cloudTimeoutJev = 0.3
    static let crossingTriggerDistance = 25.0 // meters

    // Optional components remain off through the core milestones.
    static let museEnabled = false
    static let jevEnabled = false
    static let depthRefinementEnabled = false
}
