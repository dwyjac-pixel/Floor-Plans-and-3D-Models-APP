import Foundation
import simd
import UIKit
import Vision

/// On-device AI for imported plans: reads the dimension labels printed on
/// the drawing (38'-0", 7'-3½", 3.66 m) with the Vision framework, so the
/// trace scale can be filled in automatically. Nothing leaves the device.
enum DimensionOCR {
    struct DetectedDimension: Identifiable {
        let id = UUID()
        let text: String
        let meters: Double
        let rect: CGRect       // image coordinates (points), top-left origin
    }

    static func recognize(in image: UIImage,
                          completion: @escaping ([DetectedDimension]) -> Void) {
        guard let cgImage = image.cgImage else {
            completion([])
            return
        }
        // Vision reports pixels; the trace screen works in UIImage points.
        let width = CGFloat(cgImage.width) / image.scale
        let height = CGFloat(cgImage.height) / image.scale

        let request = VNRecognizeTextRequest { request, _ in
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            var found: [DetectedDimension] = []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first,
                      let meters = parse(candidate.string) else { continue }
                let box = observation.boundingBox   // normalized, bottom-left origin
                found.append(DetectedDimension(
                    text: candidate.string.trimmingCharacters(in: .whitespaces),
                    meters: meters,
                    rect: CGRect(x: box.minX * width,
                                 y: (1 - box.maxY) * height,
                                 width: box.width * width,
                                 height: box.height * height)))
            }
            DispatchQueue.main.async { completion(found) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    /// Parses drawing dimension text: `38'-0"`, `7'-3½"`, `12' 6"`,
    /// `18'-6 1/2"`, `3.66 m`. Returns metres, or nil for non-dimensions.
    static func parse(_ raw: String) -> Double? {
        let text = raw
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "″", with: "\"")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")

        if let regex = try? NSRegularExpression(pattern: #"(\d+[.,]\d+)\s*[mM]\b"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text),
           let value = Double(text[range].replacingOccurrences(of: ",", with: ".")),
           (0.4...30).contains(value) {
            return value
        }

        // The whole-inches group must not swallow the numerator of a
        // fraction-only measurement like 5'-1/2" (was parsed as 5' 1"); the
        // negative lookahead keeps a digit followed by '/' out of it (QA-051).
        guard let regex = try? NSRegularExpression(
            pattern: #"(\d{1,3})\s*'\s*-?\s*(\d{1,2}(?![/\d]))?\s*(½|¼|¾|1/2|1/4|3/4)?"#),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func group(_ index: Int) -> String? {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let feetText = group(1), let feet = Double(feetText) else { return nil }
        let inches = group(2).flatMap(Double.init) ?? 0
        guard inches < 12 else { return nil }
        let fraction: Double
        switch group(3) {
        case "½", "1/2": fraction = 0.5
        case "¼", "1/4": fraction = 0.25
        case "¾", "3/4": fraction = 0.75
        default: fraction = 0
        }
        let meters = feet * 0.3048 + (inches + fraction) * 0.0254
        return (0.4...30).contains(meters) ? meters : nil
    }
}

/// On-device line-work analysis of an imported plan: corner candidates for
/// tap magnetism, and — when the drawing is clean enough — a proposed room
/// outline the user can accept as the whole trace.
enum PlanVision {
    struct Analysis {
        var cornerCandidates: [CGPoint] = []   // image points, top-left origin
        var outlineProposal: [CGPoint] = []    // ordered polygon, image points
    }

    static func analyze(_ image: UIImage, completion: @escaping (Analysis) -> Void) {
        guard let cgImage = image.cgImage else {
            completion(Analysis())
            return
        }
        let width = CGFloat(cgImage.width) / image.scale
        let height = CGFloat(cgImage.height) / image.scale

        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.0
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 1024

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            var analysis = Analysis()
            guard let observation = request.results?.first else {
                DispatchQueue.main.async { completion(analysis) }
                return
            }

            func imagePoint(_ point: simd_float2) -> CGPoint {
                CGPoint(x: CGFloat(point.x) * width,
                        y: (1 - CGFloat(point.y)) * height)
            }

            var candidates: [CGPoint] = []
            var bestOutline: (points: [CGPoint], area: CGFloat)?
            for index in 0..<observation.contourCount {
                guard let contour = try? observation.contour(at: index),
                      let simplified = try? contour.polygonApproximation(epsilon: 0.004) else {
                    continue
                }
                let points = simplified.normalizedPoints.map(imagePoint)
                guard points.count >= 3 else { continue }
                guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                      let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
                    continue
                }
                let boxWidth = maxX - minX
                let boxHeight = maxY - minY

                // Corners of any decent-sized shape become snap magnets.
                if boxWidth > width * 0.04 || boxHeight > height * 0.04 {
                    candidates.append(contentsOf: points)
                }

                // Outline proposal: room-sized, but not the sheet border.
                let fractionW = boxWidth / width
                let fractionH = boxHeight / height
                if fractionW > 0.25, fractionH > 0.25, fractionW < 0.92, fractionH < 0.92,
                   points.count >= 4, points.count <= 24 {
                    var doubled: CGFloat = 0
                    for pointIndex in 0..<points.count {
                        let a = points[pointIndex]
                        let b = points[(pointIndex + 1) % points.count]
                        doubled += a.x * b.y - b.x * a.y
                    }
                    let area = abs(doubled) / 2
                    if area > (bestOutline?.area ?? 0) {
                        bestOutline = (points, area)
                    }
                }
            }
            analysis.cornerCandidates = candidates
            analysis.outlineProposal = bestOutline?.points ?? []
            DispatchQueue.main.async { completion(analysis) }
        }
    }
}
