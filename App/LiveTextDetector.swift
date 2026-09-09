import Vision
import CoreImage

final class LiveTextDetector: @unchecked Sendable {
    func recognize(_ buffer: CVPixelBuffer) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.025
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .filter { !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        } catch { return [] }
    }
}
