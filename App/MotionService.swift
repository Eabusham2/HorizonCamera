import Foundation
import CoreMotion

final class MotionService: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.name = "camera.motion"; q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive; return q
    }()
    private let lock = NSLock()
    private var history = MotionHistory()
    private var lastError: String?
    var available: Bool { manager.isDeviceMotionAvailable }
    func start() {
        guard available, !manager.isDeviceMotionActive else { return }
        lock.lock(); history.clear(); lastError = nil; lock.unlock()
        manager.deviceMotionUpdateInterval = 1.0 / 200.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, error in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if let error { self.lastError = error.localizedDescription }
            guard let m = motion else { return }
            self.history.append(MotionReading(time: m.timestamp, gx: m.gravity.x, gy: m.gravity.y,
                                              gz: m.gravity.z, rateZ: m.rotationRate.z))
        }
    }
    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.lock(); history.clear(); lock.unlock()
    }
    func sample(at hostSeconds: Double) -> MotionReading? {
        lock.lock(); defer { lock.unlock() }
        return history.sample(at: hostSeconds)
    }
    var errorDescription: String? {
        lock.lock(); defer { lock.unlock() }; return lastError
    }
}
