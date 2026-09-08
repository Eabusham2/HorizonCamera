import Foundation
import Vision
import CoreImage

/// Frame-queue confined. A failed tracker NEVER silently reacquires another object.
final class SubjectTracker {
    enum State: String { case idle = "Tap a subject", acquiring = "Acquiring", locked = "Locked", lost = "Lost — tap to reacquire" }
    private var handler = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?
    private(set) var box: CGRect?
    private(set) var anchor = Point2(0.5, 0.5)
    private(set) var confidence: Float = 0
    private(set) var state: State = .idle
    private var lastVisionTime = -Double.infinity
    private var misses = 0
    func reset() {
        request?.isLastFrame = true; request = nil; handler = VNSequenceRequestHandler()
        box = nil; confidence = 0; state = .idle; misses = 0; lastVisionTime = -.infinity
    }
    func seed(normalizedBox: CGRect, anchor: Point2) {
        reset()
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rect = normalizedBox.intersection(unit)
        guard rect.width >= 0.01, rect.height >= 0.01 else { return }
        let observation = VNDetectedObjectObservation(boundingBox: rect)
        let r = VNTrackObjectRequest(detectedObjectObservation: observation)
        r.trackingLevel = .accurate
        request = r; box = rect; self.anchor = anchor; state = .acquiring
    }
    func update(image: CIImage, time: Double) {
        guard let request else { return }
        // Bound Vision cost at 30 Hz, even for 60/120 fps camera streams.
        guard time - lastVisionTime >= 1.0 / 31 else { return }
        lastVisionTime = time
        let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        do {
            try handler.perform([request], on: small)
            guard let observation = request.results?.first as? VNDetectedObjectObservation, observation.confidence >= 0.35 else {
                misses += 1; confidence = 0
                if misses >= 3 { lose() }
                return
            }
            if let old = box, state == .locked,
               hypot(observation.boundingBox.midX - old.midX, observation.boundingBox.midY - old.midY) > 0.30 {
                lose(); return
            }
            request.inputObservation = observation
            box = observation.boundingBox; confidence = observation.confidence
            misses = 0; state = .locked
        } catch { lose() }
    }
    private func lose() {
        request?.isLastFrame = true; request = nil; state = .lost; confidence = 0
    }
    var target: Point2? {
        guard state == .locked || state == .acquiring, let box else { return nil }
        return Point2(box.midX, box.midY)
    }
}
