import Foundation

public enum RecordingCadence: Equatable, Sendable {
    case realtime
    case slowMotion(captureFPS: Double, playbackFPS: Double)
    case timeLapse(interval: Double, playbackFPS: Double)
    public var recordsAudio: Bool { if case .realtime = self { return true }; return false }
}

/// Turns camera-clock times into a monotonic movie timeline. Timelapse skips
/// actual frames; slo-mo stretches presentation times. Neither fakes the FPS label.
public struct RecordingTimeline: Sendable {
    public let cadence: RecordingCadence
    public private(set) var origin: Double?
    public private(set) var count = 0
    private var lastAcceptedSource: Double?
    private var lastSource: Double?
    private var lastOutput: Double?
    public init(cadence: RecordingCadence) { self.cadence = cadence }
    public mutating func accept(sourceTime: Double) -> Double? {
        guard sourceTime.isFinite, lastSource.map({ sourceTime > $0 }) ?? true else { return nil }
        lastSource = sourceTime
        if origin == nil { origin = sourceTime }
        let result: Double
        switch cadence {
        case .realtime:
            result = sourceTime - (origin ?? sourceTime)
        case let .slowMotion(captureFPS, playbackFPS):
            guard captureFPS > 0, playbackFPS > 0 else { return nil }
            result = (sourceTime - (origin ?? sourceTime)) * captureFPS / playbackFPS
        case let .timeLapse(interval, playbackFPS):
            guard interval > 0, playbackFPS > 0 else { return nil }
            if let last = lastAcceptedSource, sourceTime - last < interval - 0.0001 { return nil }
            result = Double(count) / playbackFPS
        }
        guard lastOutput.map({ result > $0 }) ?? true else { return nil }
        lastAcceptedSource = sourceTime; lastOutput = result; count += 1
        return result
    }
    public func audioTime(sourceTime: Double) -> Double? {
        guard cadence.recordsAudio, let origin, sourceTime.isFinite, sourceTime >= origin else { return nil }
        return sourceTime - origin
    }
}
