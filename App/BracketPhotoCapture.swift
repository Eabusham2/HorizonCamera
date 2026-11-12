import AVFoundation
import Foundation

struct BracketPhotoPacket {
    let images: [Data]
    let timestamps: [CMTime]
    let settings: CameraSettings

    func validate(expectedFrameCount: Int) throws {
        guard expectedFrameCount >= 2, images.count == expectedFrameCount,
              timestamps.count == expectedFrameCount, images.allSatisfy({ !$0.isEmpty }) else {
            throw CameraFailure.message("The computational photo did not return every requested bracket frame.")
        }
    }
}

final class BracketPhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    let id: Int64
    private let settings: CameraSettings
    private let expectedFrameCount: Int
    private let completion: (Result<BracketPhotoPacket, Error>) -> Void
    private let lock = NSLock()
    private var images: [Data] = []
    private var timestamps: [CMTime] = []
    private var error: Error?

    init(id: Int64, settings: CameraSettings, expectedFrameCount: Int, completion: @escaping (Result<BracketPhotoPacket, Error>) -> Void) {
        self.id = id; self.settings = settings; self.expectedFrameCount = expectedFrameCount; self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if let error { self.error = error; return }
        guard !photo.isRawPhoto, let data = photo.fileDataRepresentation(), !data.isEmpty else {
            self.error = CameraFailure.message("The camera returned an empty or unexpected bracket frame."); return
        }
        images.append(data); timestamps.append(photo.timestamp)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        let failure = error ?? self.error
        let frames = images, times = timestamps
        lock.unlock()
        if let failure { completion(.failure(failure)); return }
        let packet = BracketPhotoPacket(images:frames,timestamps:times,settings:settings)
        do {
            try packet.validate(expectedFrameCount:expectedFrameCount)
            completion(.success(packet))
        } catch {
            completion(.failure(error))
        }
    }
}
