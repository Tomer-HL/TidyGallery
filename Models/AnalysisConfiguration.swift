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

    /// Upper bound on how far apart in time two photos can be and still be
    /// considered for the same near-duplicate group.
    ///
    /// This is deliberately generous (30 minutes). People reshoot the same
    /// subject over seconds *to minutes*, not only in a machine-gun burst, so a
    /// tight window (the old 10s) missed most real duplicates. Visual similarity
    /// (`featurePrintSimilarityThreshold`) remains the actual test for
    /// "duplicate"; this only caps how far the search looks ahead in time.
    var burstTimeWindow: TimeInterval = 1800

    /// How many subsequent photos (in capture-time order) each photo is compared
    /// against when hunting for near-duplicates. Bounds clustering to O(n·k) so
    /// it stays fast on 20k+ libraries while still catching duplicates that are
    /// spread across a shooting session rather than a rapid burst.
    var duplicateNeighborLookahead: Int = 60

    /// Feature-print distance threshold below which two images inside the same
    /// time bucket are considered visually similar and merged into one stack.
    ///
    /// `FeaturePrintObservation.distance(to:)` returns an L2 distance where
    /// **smaller means more similar**.
    ///
    /// Calibrated on a real sample (CalibrationTool): burst/duplicate pairs
    /// clustered at 0.16–0.30, unrelated photos at 0.77–1.25, with an empty gap
    /// between. 0.35 sits just above the observed duplicate ceiling (0.30) while
    /// staying far below the "different scene" floor.
    ///
    /// Tightened from 0.45: photos that merely share a composition — most
    /// notably two different pages of the same book — were being merged into one
    /// stack. Real near-duplicates cap out at 0.30, so this loses nothing.
    var featurePrintSimilarityThreshold: Float = 0.35

    /// Stricter similarity required before two *document* photos are treated as
    /// near-duplicates. Pages of text share a near-identical layout, so the
    /// generic threshold happily merges genuinely different pages. Two shots of
    /// the *same* page still cluster (they're nearly pixel-identical); different
    /// pages don't. Applied when either photo carries the `.documents` tag.
    var documentSimilarityThreshold: Float = 0.20

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

    /// "Possibly blurry" is a **relative** judgement, not an absolute one.
    /// Laplacian variance depends on content *and* image size, so a fixed cutoff
    /// over-flags on some libraries and under-flags on others. A photo is
    /// surfaced only when it is BOTH below this absolute ceiling AND within the
    /// softest `blurryPercentile` of the whole library, and the list is capped at
    /// `blurryMaxCount`. Together these stop the category from ever becoming a
    /// catch-all when every photo happens to score low. It stays
    /// SURFACING-ONLY — never pre-selected — so a false positive costs a glance,
    /// never a photo.
    var blurrySinglesSharpnessCeiling: Double = 0.20

    /// Only the softest fraction of the library is eligible for "Possibly
    /// blurry" (combined with the absolute ceiling above).
    var blurryPercentile: Double = 0.15

    /// Hard cap on how many photos "Possibly blurry" ever surfaces.
    var blurryMaxCount: Int = 200

    /// How many of the highest-resolution stills to measure as "big file"
    /// candidates. Reading real on-disk size for a whole 20k library is
    /// expensive, so we bound the candidate pool to the largest-by-resolution
    /// stills (plus all Live Photos) and measure only those.
    var bigFileCandidateStillLimit: Int = 300

    /// How many entries the "Big files" screen shows after measuring real sizes
    /// and sorting largest-first.
    var bigFileDisplayLimit: Int = 100

    /// Minimum real on-disk size for a photo to count as a "big file". Keeps the
    /// category meaningful (largest space hogs) instead of listing every photo.
    var bigFileMinBytes: Int64 = 5_000_000   // ~5 MB

    // MARK: Scene classification (Food / Pets / Documents…)

    /// Floor for a Vision classification label to be considered at all.
    ///
    /// Deliberately low. `VNClassifyImageRequest` is a multi-label classifier
    /// over a ~1300-class taxonomy, so confidence is spread thin — even a
    /// correct "food" label routinely scores well under 0.5. An earlier 0.5 gate
    /// meant almost nothing was ever tagged. We instead take the top few labels
    /// (see `sceneClassificationTopLabels`) above this small floor, which is what
    /// the taxonomy's scoring actually supports.
    var sceneClassificationMinConfidence: Float = 0.05

    /// How many of the highest-confidence labels to consider per image. Keeping
    /// this small stops the long tail of low-confidence noise from producing
    /// false category matches.
    var sceneClassificationTopLabels: Int = 10

    /// A photo counts as a selfie when its largest detected face covers at least
    /// this fraction of the frame (normalised area). ~0.10 catches close-up
    /// portraits while ignoring group/scene shots with small distant faces.
    var selfieMinFaceAreaFraction: Double = 0.10

    static let `default` = AnalysisConfiguration()
}
