import AppKit
import Vision

enum OCR {
    static let languageCodes: [String] = {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        return (try? req.supportedRecognitionLanguages()) ?? ["en-US"]
    }()

    static let languageNames: [String] = languageCodes.map {
        Locale.current.localizedString(forIdentifier: $0) ?? $0
    }

    /// One-shot override of the "Keep line breaks" pref (set by the OCR shortcuts).
    @MainActor static var lineBreakOverride: Bool?

    /// Recognized text of an image (blocking work off the main thread).
    static func text(in image: CGImage, language: String?, separator: String) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if let language { request.recognitionLanguages = [language] } else { request.automaticallyDetectsLanguage = true }
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: separator)
        }.value
    }

    @MainActor
    static func recognize(_ capture: Capture) {
        let langIndex = Prefs.int("ocr.language")
        let language = langIndex > 0 ? languageCodes[safe: langIndex - 1] : nil
        let separator = (lineBreakOverride ?? Prefs.bool("ocr.lineBreaks")) ? "\n" : " "
        lineBreakOverride = nil
        Task { @MainActor in
            let text = await text(in: capture.image, language: language, separator: separator)
            if text.isEmpty {
                Toast.show("No text found", symbol: "text.magnifyingglass")
            } else {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                Toast.show("Text copied", symbol: "text.viewfinder")
            }
        }
    }
}
