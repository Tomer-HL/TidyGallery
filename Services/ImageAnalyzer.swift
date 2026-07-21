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
//  Image aesthetics use Apple's newer async Vision request
//  (`CalculateImageAestheticsScoresRequest`, iOS 18+/macOS 15+) — it doesn't run
//  on the iOS Simulator but works on device and on the CI Mac. It's best-effort:
//  a failure leaves `ShotScore.aesthetics` nil, which the scorer treats as
//  neutral, so ranking still works.
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
    /// On-device content categories (food, pets, documents…). May be empty.
    var sceneTags: Set<SceneCategory> = []
}

/// On-device image analysis. Reusable across the whole scan.
actor ImageAnalyzer {

    enum AnalyzerError: Error {
        case featurePrintUnavailable
    }

    private var config: AnalysisConfiguration

    init(config: AnalysisConfiguration = .default) {
        self.config = config
    }

    /// Adopt new analysis settings (from the Settings screen). The caller is
    /// responsible for discarding cached analysis, since results already stored
    /// were produced under the old settings.
    func updateConfiguration(_ newConfig: AnalysisConfiguration) {
        config = newConfig
    }

    /// Analyse a single image. `isFavorite` is threaded in from the asset
    /// snapshot so the resulting score can be persisted whole.
    ///
    /// The feature print is required (clustering depends on it); if Vision can't
    /// produce one we throw. Face analysis is best-effort — a failure there
    /// degrades to "no faces" rather than failing the whole image.
    func analyze(image: CGImage, isFavorite: Bool) async throws -> AnalyzedImage {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])

        let featurePrintRequest = VNGenerateImageFeaturePrintRequest()
        let faceRequest = VNDetectFaceLandmarksRequest()

        // Feature print + faces run in a single classic-API handler pass.
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

        // On-device aesthetics via the newer async Vision request (best-effort).
        let aesthetics = await Self.aestheticsScore(for: image)

        // On-device content classification (best-effort; empty on failure).
        var sceneTags = classifyScene(image: image)
        // Selfies come from face geometry, not a classifier label: one or more
        // faces large enough to fill a good part of the frame.
        if Self.isSelfie(faces: faces, minFaceAreaFraction: config.selfieMinFaceAreaFraction) {
            sceneTags.insert(.selfies)
        }

        let score = ShotScore(
            sharpness: sharpness,
            aesthetics: aesthetics,
            faceQuality: faceQuality,
            isFavorite: isFavorite
        )
        return AnalyzedImage(featurePrint: print, score: score, sceneTags: sceneTags)
    }

    // MARK: - Scene classification (content categories)

    /// Runs Vision's on-device image classifier and folds the confident labels
    /// into our high-level `SceneCategory` set. Best-effort and isolated in its
    /// own request handler so a classification failure never affects the required
    /// feature print. Returns an empty set on any failure.
    private func classifyScene(image: CGImage) -> Set<SceneCategory> {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = request.results ?? []
        // Take the strongest few labels above a low floor rather than applying a
        // high absolute confidence gate: this classifier spreads confidence
        // across a very large taxonomy, so correct labels often score low.
        let confidentIdentifiers = observations
            .filter { $0.confidence >= config.sceneClassificationMinConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(config.sceneClassificationTopLabels)
            .map(\.identifier)
        return SceneCategory.categories(forIdentifiers: Array(confidentIdentifiers))
    }

    /// A photo reads as a selfie when at least one detected face is large enough
    /// to fill a meaningful fraction of the frame (a close-up portrait), which
    /// distinguishes selfies from group/scene photos with small distant faces.
    /// `VNFaceObservation.boundingBox` is normalised to the image, so the area
    /// fraction needs no image dimensions.
    private static func isSelfie(faces: [VNFaceObservation], minFaceAreaFraction: Double) -> Bool {
        let largestFaceArea = faces
            .map { Double($0.boundingBox.width * $0.boundingBox.height) }
            .max() ?? 0
        return largestFaceArea >= minFaceAreaFraction
    }

    // MARK: - Aesthetics (newer Vision API)

    /// Apple's overall image-aesthetics score, normalised from its native
    /// `[-1, 1]` range to `[0, 1]`. Returns `nil` if unavailable (e.g. running on
    /// the iOS Simulator, or the request fails) so the scorer falls back to neutral.
    private static func aestheticsScore(for image: CGImage) async -> Double? {
        do {
            let request = CalculateImageAestheticsScoresRequest()
            let observation = try await request.perform(on: image)
            return (Double(observation.overallScore) + 1.0) / 2.0
        } catch {
            return nil
        }
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
