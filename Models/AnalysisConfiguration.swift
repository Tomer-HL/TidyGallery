//
//  AnalysisConfiguration.swift
//  TidyGallery
//
//  Central, tunable knobs for the analysis pipeline. Keeping every magic
//  number in one `Sendable` value type means thresholds are documented,
//  testable, and never hard-coded deep inside a service.
//

import Foundation

/// All tunable parameters for stack clustering and best-shot scoring.
///
/// The defaults below reflect the Phase 1 product decisions:
/// - **Tight ~10s burst window** for grouping.
/// - **Conservative pre-selection** (only clearly-inferior near-duplicates).
/// - **`isFavorite` is a hard lock**, enforced in `ShotScorer`, not here.
struct AnalysisConfiguration: Sendable, Equatable {

    // MARK: Clustering

    /// Maximum time between two consecutive photos for them to be considered
    /// part of the same burst. Photos are sorted by `creationDate`; a gap
    /// larger than this starts a new time bucket.
    var burstTimeWindow: TimeInterval = 10

    /// Feature-print distance threshold below which two images inside the same
    /// time bucket are considered visually similar and merged into one stack.
    ///
    /// `FeaturePrintObservation.distance(to:)` returns an L2 distance where
    /// **smaller means more similar**.
    ///
    /// Calibrated on a real sample (CalibrationTool): burst/duplicate pairs
    /// clustered at 0.16–0.30, unrelated photos at 0.77–1.25, with an empty gap
    /// between. 0.45 sits in that gap with margin on both sides — comfortably
    /// above the duplicate ceiling, well below the "different scene" floor.
    var featurePrintSimilarityThreshold: Float = 0.45

    /// If both assets carry a location, discard the pair from a burst when they
    /// are farther apart than this (meters). Guards against grouping photos that
    /// happen to be near in time but taken in different places (e.g. two people
    /// on two phones). Ignored when either asset lacks location.
    var maxBurstDistanceMeters: Double = 60

    // MARK: Scoring weights (sum is normalised, so relative magnitude matters)

    /// Weight of sharpness (anti-blur) in the composite best-shot score.
    var sharpnessWeight: Double = 0.40

    /// Weight of face quality (eyes open + smiling) in the composite score.
    var faceQualityWeight: Double = 0.35

    /// Weight of the on-device aesthetics score in the composite score.
    var aestheticsWeight: Double = 0.25

    // MARK: Conservative pre-selection gates

    /// A stack-mate is only pre-selected for deletion when it is at least this
    /// similar to the best shot (distance <= this). Prevents deleting a photo
    /// that merely happens to share a stack but is visually distinct.
    ///
    /// Calibration validated 0.35: it sits just above the observed duplicate
    /// ceiling (~0.30), so only genuine near-duplicates are ever auto-selected —
    /// stricter than the clustering threshold, matching the safety-first rule.
    var preselectSimilarityThreshold: Float = 0.35

    /// A stack-mate is only pre-selected when its composite score is at least
    /// this fraction *below* the best shot's score. Prevents deleting a photo
    /// that is nearly as good as the winner.
    var preselectQualityMargin: Double = 0.15

    // MARK: Phase 3 — standalone cleanup categories

    /// A standalone still is surfaced under "Possibly blurry" only when its
    /// **absolute** sharpness is at or below this. Deliberately low: Laplacian
    /// variance is content-dependent (see `BlurDetector`), so an absolute gate
    /// can only be trusted to flag clearly-soft images. Blurry singles are a
    /// SURFACING-ONLY category — they are never pre-selected for deletion, so a
    /// false positive costs the user a glance, never a photo.
    var blurrySinglesSharpnessCeiling: Double = 0.12

    /// How many of the highest-resolution stills to measure as "big file"
    /// candidates. Reading real on-disk size for a whole 20k library is
    /// expensive, so we bound the candidate pool to the largest-by-resolution
    /// stills (plus all Live Photos) and measure only those.
    var bigFileCandidateStillLimit: Int = 300

    /// How many entries the "Big files" screen shows after measuring real sizes
    /// and sorting largest-first.
    var bigFileDisplayLimit: Int = 100

    static let `default` = AnalysisConfiguration()
}
