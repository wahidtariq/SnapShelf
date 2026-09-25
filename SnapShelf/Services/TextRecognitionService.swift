import Foundation
import UniformTypeIdentifiers
import Vision

/// Recognizes text inside a screenshot with Vision, so the Library's search field can match text
/// that appears *in* an image (e.g. "invoice", "error") and not just its file name.
///
/// A plain `Sendable` struct rather than an actor — each call is a single self-contained Vision
/// request with no shared mutable state, so there's nothing to isolate. Callers (the importer
/// actor) decide how many recognitions run at once.
struct TextRecognitionService: Sendable {
    /// Recognizes text in the image at `url`. PDFs are skipped and return an empty string —
    /// rendering page 1 through Core Graphics just to hand it to Vision was judged not worth the
    /// complexity for a screenshot library that's overwhelmingly PNG/HEIC; revisit if PDFs turn
    /// out to matter in practice.
    func recognizeText(in url: URL) async throws -> String {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            return ""
        }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let observations = try await request.perform(on: url)
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
