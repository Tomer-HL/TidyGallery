//
//  ImageAnalyzer.swift
//  TidyGallery
//
//  The heart of Phase 1. An `actor` that, given a downscaled `CGImage`,
//  produces a `Sendable` analysis: a feature print for clustering plus a
//  `ShotScore` (sharpness, aesthetics, face quality). All work is on-device.
//
//  Design notes
//  ------------
//  • It's an `actor` so concurrent callers are serialised safely and no mutable
//    Vision state is shared. Vision request objects are created per-call and
//    never escape the actor, so nothing non-`Sendable` crosses a boundary.
//  • Inputs/outputs are value types (`CGImage` in — created on the library
//    actor — and `AnalyzedImage` out).
//  • Written against the modern async Vision API introduced in iOS 18
//    (`GenerateImageFeaturePrintRequest`, `DetectFaceLandmarksRequest`,
//    `CalculateImageAestheticsScoresRequest`). See the README's
//    "Symbols to verify" note — these are new-SDK names; confirm against your
//    Xcode version, as the older `VNImageRequestHandler` API is also available
//    as a fallback.
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
    /// produce one we throw. Aesthetics and face analysis are best-effort — a
    /// failure there degrades to a neutral sub-score rather than failing the
    /// whole image.
    func analyze(image: CGImage, isFavorite: Bool) async throws -> AnalyzedImage {

        // Run the three Vision requests concurrently; they're independent.
        async let featurePrint = generateFeaturePrint(for: image)
        async let aesthetics = computeAesthetics(for: image)
        async let face = evaluateFaces(in: image)

        guard let print = try await featurePrint else {
            throw AnalyzerError.featurePrintUnavailable
        }

        // Sharpness is CPU-bound (Accelerate); fine to compute inline.
        let sharpness = BlurDetector.sharpness(of: image)

        let score = ShotScore(
            sharpness: sharpness,
            aesthetics: await aesthetics,
            faceQuality: await face,
            isFavorite: isFavorite
        )
        return AnalyzedImage(featurePrint: print, score: score)
    }

    // MARK: - Feature print (clustering embedding)

    private func generateFeaturePrint(for image: CGImage) async throws -> FeaturePrint? {
        var request = GenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFit

        // `perform(on:)` returns a `FeaturePrintObservation`. We copy its raw
        // Float32 elements into our `Sendable` value type immediately.
        let observation = try await request.perform(on: image)
        return Self.extractVector(from: observation)
    }

    /// Copies the observation's element data into a `[Float]`. The observation
    /// stores its vector as `Data` of `elementType` floats with `elementCount`.
    private static func extractVector(from observation: FeaturePrintObservation) -> FeaturePrint? {
        let count = observation.elementCount
        guard count > 0 else { return nil }
        let data = observation.data
        // FeaturePrint elements are Float32 in the current Vision implementation.
        let floats: [Float] = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
        guard floats.count == count else { return nil }
        return FeaturePrint(vector: floats)
    }

    // MARK: - Aesthetics (iOS 18 built-in quality signal)

    private func computeAesthetics(for image: CGImage) async -> Double? {
        do {
            let request = CalculateImageAestheticsScoresRequest()
            let observation = try await request.perform(on: image)
            // `overallScore` is roughly [-1, 1]; normalise to [0, 1].
            return (Double(observation.overallScore) + 1.0) / 2.0
        } catch {
            return nil   // best-effort: neutral if unavailable
        }
    }

    // MARK: - Face landmarks → eyes-open / smiling

    private func evaluateFaces(in image: CGImage) async -> FaceQuality {
        do {
            let request = DetectFaceLandmarksRequest()
            let faces = try await request.perform(on: image)
            guard !faces.isEmpty else { return .noFaces }

            var eyeScores: [Double] = []
            var smileScores: [Double] = []

            for face in faces {
                guard let landmarks = face.landmarks else { continue }

                // Eyes: average EAR of both eyes if present.
                var earValues: [Double] = []
                if let left = landmarks.leftEye,
                   let ear = FaceLandmarkEvaluator.eyeAspectRatio(Self.points(left)) {
                    earValues.append(ear)
                }
                if let right = landmarks.rightEye,
                   let ear = FaceLandmarkEvaluator.eyeAspectRatio(Self.points(right)) {
                    earValues.append(ear)
                }
                if !earValues.isEmpty {
                    let avgEAR = earValues.reduce(0, +) / Double(earValues.count)
                    eyeScores.append(FaceLandmarkEvaluator.opennessScore(fromEAR: avgEAR))
                }

                // Smile: from the outer-lip contour.
                if let lips = landmarks.outerLips,
                   let smile = FaceLandmarkEvaluator.smileScore(outerLips: Self.points(lips)) {
                    smileScores.append(smile)
                }
            }

            // Aggregate per FaceQuality's documented policy: worst eyes, best smile.
            let eyesOpen = eyeScores.min()
            let smile = smileScores.max()
            return FaceQuality(
                faceCount: faces.count,
                eyesOpenScore: eyesOpen,
                smileScore: smile
            )
        } catch {
            return .noFaces   // best-effort
        }
    }

    /// Extracts normalised points from a Vision landmark region. `normalizedPoints`
    /// are in the face's 0...1 space, which is all our geometry helpers need.
    private static func points(_ region: FaceLandmarks2D.Region) -> [CGPoint] {
        region.normalizedPoints
    }
}
