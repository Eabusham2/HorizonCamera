import Foundation
import CoreLocation
import ImageIO

final class CaptureLocation: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = CaptureLocation()
    private let lock = NSLock()
    private var lastLocation: CLLocation?
    private var authorizationContinuation: CheckedContinuation<Void,Never>?
    private var startUpdatesAfterAuthorization=false
    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        return manager
    }()

    func requestAuthorizationOnly() async {
        if manager.authorizationStatus != .notDetermined { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else { continuation.resume(); return }
                guard self.manager.authorizationStatus == .notDetermined else { continuation.resume(); return }
                self.authorizationContinuation=continuation
                self.manager.requestWhenInUseAuthorization()
            }
        }
    }

    func request() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.manager.authorizationStatus {
            case .notDetermined:
                self.startUpdatesAfterAuthorization=true
                self.manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                self.manager.startUpdatingLocation()
            default: break
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined, let continuation=authorizationContinuation {
            authorizationContinuation=nil; continuation.resume()
        }
        if (manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse), startUpdatesAfterAuthorization {
            startUpdatesAfterAuthorization=false
            manager.startUpdatingLocation()
        } else if manager.authorizationStatus != .notDetermined {
            startUpdatesAfterAuthorization=false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last, value.horizontalAccuracy >= 0 else { return }
        lock.lock(); lastLocation = value; lock.unlock()
        if value.horizontalAccuracy <= 50 { manager.stopUpdatingLocation() }
    }

    func stop() { DispatchQueue.main.async { [weak self] in self?.manager.stopUpdatingLocation() } }

    func current(maxAge: TimeInterval = 300) -> CLLocation? {
        lock.lock(); defer { lock.unlock() }
        guard let value = lastLocation, abs(value.timestamp.timeIntervalSinceNow) <= maxAge else { return nil }
        return value
    }

    static func iso6709(_ location: CLLocation) -> String {
        String(format: "%+.6f%+.6f%+.1f/", location.coordinate.latitude, location.coordinate.longitude, location.altitude)
    }

    static func gpsDictionary(_ location: CLLocation) -> [String: Any] {
        let latitude = location.coordinate.latitude, longitude = location.coordinate.longitude
        return [
            kCGImagePropertyGPSLatitude as String: abs(latitude),
            kCGImagePropertyGPSLatitudeRef as String: latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(longitude),
            kCGImagePropertyGPSLongitudeRef as String: longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSAltitude as String: abs(location.altitude),
            kCGImagePropertyGPSAltitudeRef as String: location.altitude >= 0 ? 0 : 1,
            kCGImagePropertyGPSHPositioningError as String: max(0, location.horizontalAccuracy)
        ]
    }
}
