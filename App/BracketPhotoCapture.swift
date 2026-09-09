import AVFoundation
import Foundation

struct BracketPhotoPacket {
    let images: [Data]
    let timestamps: [CMTime]
    let settings: CameraSettings
}

final class BracketPhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    let id: Int64
    private let settings: CameraSettings
    private let completion: (Result<BracketPhotoPacket, Error>) -> Void
    private let lock = NSLock()
    private var images: [Data] = []
    private var timestamps: [CMTime] = []
    private var error: Error?

    init(id: Int64, settings: CameraSettings, completion: @escaping (Result<BracketPhotoPacket, Error>) -> Void) {
        self.id = id; self.settings = settings; self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if let error { self.error = error; return }
        guard !photo.isRawPhoto, let data = photo.fileDataRepresentation() else { return }
        images.append(data); timestamps.append(photo.timestamp)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        let failure = error ?? self.error
        let frames = images, times = timestamps
        lock.unlock()
        if let failure { completion(.failure(failure)); return }
        guard frames.count >= 2 else {
            completion(.failure(CameraFailure.message("The computational photo bracket did not return enough frames."))); return
        }
        completion(.success(BracketPhotoPacket(images:frames,timestamps:times,settings:settings)))
    }
}
