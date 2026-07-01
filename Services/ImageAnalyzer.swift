//
//  ImageAnalyzer.swift
//  TidyGallery
//
//  The heart of Phase 1. An `actor` that, given a downscaled `CGImage`,
//  produces a `Sendable` analysis: a feature print for clustering plus a
//  `ShotScore` (sharpness + face quality).
//
//  Vision API choice
//  -----------------
//  This uses the CLASSIC, long-stable `VNImageRequestHandler` API
//  (`VNGenerateImageFeaturePrintRequest`, `VNDetectFaceLandmarksRequest`,
//  `VNFeaturePrintObservation`, `VNFaceLandmarks2D`) rather than the newer
//  Swift-only Vision types, whose symbol names shift between SDK versions.
//  These names have been stable since iOS 13 and compile reliably.
//
//  The iOS 18+ image-aesthetics score is intentionally NOT wired up yet — its
//  new-API symbols need on-device verification. `ShotScore.aesthetics` is left
//  `nil`, which the scorer treats as a neutral value, so ranking is unaffected.
//  It can be layered in later without touching the rest of the pipeline.
//
//  Concurrency: request objects are created and consumed entirely inside the
//  actor and never escape, so nothing non-`Sendable` crosses a boundary.
//

import Foundation
import Vision
import CoreGraphics

/// A fully-computed, `Sendable` analysis result for one image.
struct AnalyzedImage: Sendable {
    let featurePrint: FeaturePrint
    let score: ShotScore
}

/// On-device image analysis. Reusable across the whole scan.
actor ImageAnalyzer {

    enum AnalyzerError: Error {
        case featurePrintUnavailable
    }

    /// Analyse a single image. `isFavorite` is threaded in from the asset
    /// snapshot so the resulting score can be persisted whole.
    ///
    /// The feature print is required (clustering depends on it); if Vision can't
    /// produce one we throw. Face analysis is best-effort — a failure there
    /// degrades to "no faces" rather than failing the whole image.
    func analyze(image: CGImage, isFavorite: Bool) throws -> AnalyzedImage {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])

        let featurePrintRequest = VNGenerateImageFeaturePrintRequest()
        let faceRequest = VNDetectFaceLandmarksRequest()

        // Both requests run in a single handler pass over the image.
        try handler.perform([featurePrintRequest, faceRequest])

        guard
            let observation = featurePrintRequest.results?.first as? VNFeaturePrintObservation,
            let print = Self.extractVector(from: observation)
        else {
            throw AnalyzerError.featurePrintUnavailable
        }

        let sharpness = BlurDetector.sharpness(of: image)
        let faces = faceRequest.results as? [VNFaceObservation] ?? []
        let faceQuality = Self.evaluateFaces(faces)

        let score = ShotScore(
            sharpness: sharpness,
            aesthetics: nil,            // deferred; scorer treats nil as neutral
            faceQuality: faceQuality,
            isFavorite: isFavorite
        )
        return AnalyzedImage(featurePrint: print, score: score)
    }

    // MARK: - Feature print → Sendable vector

    /// Copies a feature-print observation's raw elements into a `[Float]`.
    /// Feature prints are Float32 in practice, but we handle the double case
    /// defensively so a future SDK change can't silently produce garbage.
    private static func extractVector(from observation: VNFeaturePrintObservation) -> FeaturePrint? {
        let count = observation.elementCount
        guard count > 0 else { return nil }
        let data = observation.data

        let floats: [Float]
        switch observation.elementType {
        case .float:
            floats = data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self).prefix(count))
            }
        case .double:
            let doubles = data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Double.self).prefix(count))
            }
            floats = doubles.map(Float.init)
        @unknown default:
            return nil
        }

        guard floats.count == count else { return nil }
        return FeaturePrint(vector: floats)
    }

    // MARK: - Face landmarks → eyes-open / smiling

    private static func evaluateFaces(_ faces: [VNFaceObservation]) -> FaceQuality {
        guard !faces.isEmpty else { return .noFaces }

        var eyeScores: [Double] = []
        var smileScores: [Double] = []

        for face in faces {
            guard let landmarks = face.landmarks else { continue }

            // Eyes: average EAR of whichever eyes are present.
            var earValues: [Double] = []
            if let left = landmarks.leftEye,
               let ear = FaceLandmarkEvaluator.eyeAspectRatio(left.normalizedPoints) {
                earValues.append(ear)
            }
            if let right = landmarks.rightEye,
               let ear = FaceLandmarkEvaluator.eyeAspectRatio(right.normalizedPoints) {
                earValues.append(ear)
            }
            if !earValues.isEmpty {
                let avgEAR = earValues.reduce(0, +) / Double(earValues.count)
                eyeScores.append(FaceLandmarkEvaluator.opennessScore(fromEAR: avgEAR))
            }

            // Smile: from the outer-lip contour.
            if let lips = landmarks.outerLips,
               let smile = FaceLandmarkEvaluator.smileScore(outerLips: lips.normalizedPoints) {
                smileScores.append(smile)
            }
        }

        // Aggregate: worst eyes (one blinker drags it down), best smile.
        return FaceQuality(
            faceCount: faces.count,
            eyesOpenScore: eyeScores.min(),
            smileScore: smileScores.max()
        )
    }
}
