import AVFoundation
import Foundation

struct PhotoPacket {
    let data: Data
    let rawData: Data?
    let liveMovie: URL?
    let timestamp: CMTime
    let settings: CameraSettings
}
final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    let id: Int64
    private let settings: CameraSettings
    private let liveURL: URL?
    private let completion: (Result<PhotoPacket, Error>) -> Void
    private let lock = NSLock()
    private var imageData: Data?
    private var rawData: Data?
    private var timestamp: CMTime = .invalid
    private var error: Error?
    init(id: Int64, settings: CameraSettings, liveURL: URL?, completion: @escaping (Result<PhotoPacket, Error>) -> Void) {
        self.id = id; self.settings = settings; self.liveURL = liveURL; self.completion = completion
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if let error { self.error = error; return }
        guard let data = photo.fileDataRepresentation() else {
            self.error = CameraFailure.message("The camera returned an empty photo."); return
        }
        if photo.isRawPhoto { rawData = data } else { imageData = data; timestamp = photo.timestamp }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { lock.lock(); self.error = error; lock.unlock() }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        let failure = error ?? self.error
        let data = imageData, raw = rawData, time = timestamp
        lock.unlock()
        if let failure { completion(.failure(failure)) }
        else if let data {
            completion(.success(PhotoPacket(data: data, rawData: raw, liveMovie: liveURL, timestamp: time, settings: settings)))
        } else { completion(.failure(CameraFailure.message("The photo did not finish processing."))) }
    }
}
