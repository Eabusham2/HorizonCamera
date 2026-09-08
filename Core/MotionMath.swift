import Foundation

public enum AngleMath {
    public static func wrap(_ a: Double) -> Double { atan2(sin(a), cos(a)) }
    public static func unwrap(_ a: Double, near previous: Double) -> Double {
        previous + wrap(a - previous)
    }
}

public struct MotionReading: Sendable {
    public let time: Double
    public let gx: Double
    public let gy: Double
    public let gz: Double
    public let rateZ: Double
    public init(time: Double, gx: Double, gy: Double, gz: Double, rateZ: Double) {
        self.time = time; self.gx = gx; self.gy = gy; self.gz = gz; self.rateZ = rateZ
    }
}

/// Access is synchronized by MotionService. A bounded, timestamped history, not
/// 'whatever attitude happens to be newest when an old video frame arrives'.
public struct MotionHistory: Sendable {
    public private(set) var readings: [MotionReading] = []
    public let capacity: Int
    public init(capacity: Int = 800) { self.capacity = max(2, capacity) }
    public mutating func clear() { readings.removeAll(keepingCapacity: true) }
    public mutating func append(_ value: MotionReading) {
        guard value.time.isFinite, value.gx.isFinite, value.gy.isFinite,
              value.gz.isFinite, value.rateZ.isFinite,
              readings.last.map({ value.time > $0.time }) ?? true else { return }
        readings.append(value)
        if readings.count > capacity { readings.removeFirst(readings.count - capacity) }
    }
    public func sample(at time: Double, tolerance: Double = 0.08) -> MotionReading? {
        guard time.isFinite, let first = readings.first, let last = readings.last,
              time >= first.time - tolerance, time <= last.time + tolerance else { return nil }
        if time <= first.time { return first }
        if time >= last.time { return last }
        var lo = 0, hi = readings.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if readings[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = readings[lo], b = readings[hi]
        let f = (time - a.time) / (b.time - a.time)
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        return MotionReading(time: time, gx: lerp(a.gx, b.gx), gy: lerp(a.gy, b.gy),
                             gz: lerp(a.gz, b.gz), rateZ: lerp(a.rateZ, b.rateZ))
    }
}

public struct HorizonSolution: Sendable {
    public let angle: Double
    public let gravityReliable: Bool
}

public struct HorizonEstimator: Sendable {
    private var previous: Double?
    private var lastTime: Double?
    private var nearVertical = false
    public init() {}
    public mutating func reset() { previous = nil; lastTime = nil; nearVertical = false }
    /// Mirror is applied to the source BEFORE this transform. An unmirrored
    /// front camera reverses camera-plane X relative to the back camera.
    public mutating func update(_ m: MotionReading, unmirroredFront: Bool = false) -> HorizonSolution {
        let sign = unmirroredFront ? -1.0 : 1.0
        let projection = hypot(m.gx, m.gy)
        if projection < 0.12 { nearVertical = true }
        if projection > 0.22 { nearVertical = false }
        let dt = min(0.10, max(0, m.time - (lastTime ?? m.time)))
        let predicted = (previous ?? 0) + sign * m.rateZ * dt
        let result: Double
        if nearVertical {
            // At the sky/ground the gravity-defined horizon is singular. Use
            // short-term gyro continuation, and expose this state to the UI.
            result = predicted
        } else {
            let measured = -atan2(sign * m.gx, -m.gy)
            result = previous.map { AngleMath.unwrap(measured, near: $0) } ?? measured
        }
        previous = result; lastTime = m.time
        return HorizonSolution(angle: result, gravityReliable: !nearVertical)
    }
}
