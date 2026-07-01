//
//  ShotScore.swift
//  TidyGallery
//
//  The per-image quality breakdown produced by the analyzer and combined by
//  ShotScorer. Kept as a transparent value type so the UI (Phase 2) can show
//  *why* a photo won or lost, and so scoring is unit-testable in isolation.
//

import Foundation

/// A fully-decomposed quality assessment for one image.
///
/// All sub-scores are normalised to `[0, 1]` where higher is better, so the
/// composite is a simple weighted sum and remains explainable.
struct ShotScore: Sendable, Hashable, Codable {

    /// Sharpness in `[0, 1]`; higher = sharper. Derived from Laplacian variance
    /// mapped through a saturating curve (see `BlurDetector`).
    let sharpness: Double

    /// On-device aesthetics in `[0, 1]` from `CalculateImageAestheticsScoresRequest`.
    /// Nil when unavailable (e.g. the request failed); treated as neutral.
    let aesthetics: Double?

    /// Face assessment; nil `combinedScore` means "no faces present".
    let faceQuality: FaceQuality

    /// `true` when the underlying `PHAsset.isFavorite`. Carried here so the
    /// scorer can enforce the hard-lock rule without re-reading the asset.
    let isFavorite: Bool

    /// Composite score in `[0, 1]`, computed with the supplied weights. Faces
    /// are folded in only when present; otherwise their weight is redistributed
    /// to sharpness and aesthetics so people-free photos aren't penalised.
    func composite(using config: AnalysisConfiguration) -> Double {
        var weightedSum = 0.0
        var totalWeight = 0.0

        weightedSum += sharpness * config.sharpnessWeight
        totalWeight += config.sharpnessWeight

        let aestheticsValue = aesthetics ?? 0.5
        weightedSum += aestheticsValue * config.aestheticsWeight
        totalWeight += config.aestheticsWeight

        if let face = faceQuality.combinedScore {
            weightedSum += face * config.faceQualityWeight
            totalWeight += config.faceQualityWeight
        }

        guard totalWeight > 0 else { return 0 }
        return weightedSum / totalWeight
    }
}
