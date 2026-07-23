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

    /// Feature-print distance under which two images that already share exact
    /// dimensions and byte size are treated as the *same* image. Identical files
    /// produce an identical embedding, so this only needs to absorb rounding.
    var exactDuplicateDistanceEpsilon: Float = 0.02

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

    /// A photo the aesthetics model rates at or above this is never called
    /// "possibly blurry", however low its Laplacian sharpness.
    ///
    /// Variance-of-Laplacian measures *detail*, not focus, so a sharp but smooth
    /// scene — a sunset, an open sky, a plain wall — scores as low as a genuinely
    /// blurry one. Real device output was a Possibly-blurry list full of sunsets.
    /// A blurry photo is also an *unpleasant* one, so the aesthetics score
    /// separates the two: it is high for the sharp sunset and low for the blur.
    /// `0.5` is the model's neutral point (its native `[-1, 1]` mapped to
    /// `[0, 1]`), so this excludes anything the model likes at all.
    var blurryExcludeAestheticsAtOrAbove: Double = 0.5

    // MARK: Analysis cost

    /// The square bound, in pixels, that photos are downscaled to before
    /// analysis. The single biggest lever on scan time.
    ///
    /// Measured on an iPhone 11 Pro Max at 512: 154 ms to load and decode each
    /// image, plus 115 ms of Vision — 269 ms per photo, which projects to about
    /// 45 minutes for 20,000 photos. Decode and Vision both scale with pixel
    /// count, and 384 is 44% fewer pixels than 512.
    ///
    /// **Two things are coupled to this value and break silently if it changes.**
    /// Laplacian sharpness is scale-dependent, so `blurrySinglesSharpnessCeiling`
    /// is calibrated *for a particular size* — halve the image and everything
    /// reads blurrier. And face landmarks need faces to be a reasonable number
    /// of pixels across, so going much below this starts losing the small,
    /// distant faces in group shots, which is exactly where eyes-closed
    /// detection earns its keep. That's why this stops at 384 rather than
    /// chasing the cost down further.
    var analysisImageSize: Int = 384

    /// How many photos are decoded and analysed at once.
    ///
    /// Was 4, which measured as only 2–3× effective parallelism — because every
    /// worker queued on the main actor for its image request. With
    /// `PhotoLibraryService` off the main actor the pool can actually be filled,
    /// so this is raised. It is a throughput/thermal trade rather than a memory
    /// one: peak footprint measured 59.8 MB against 1.99 GB of headroom, so
    /// memory is nowhere near the limiting factor.
    var maxConcurrentAnalyses: Int = 6

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

    /// Floor for a Vision classification label to be trusted.
    ///
    /// Finding the right value took two corrections. `VNClassifyImageRequest`
    /// spreads confidence across a ~1300-class taxonomy, so a 0.5 gate tagged
    /// almost nothing. But dropping to 0.05 went too far the other way: at that
    /// level the tail is noise, and a single spurious "cat" or "poster" was
    /// enough to file a photo of a child under Pets or Documents. 0.15 keeps
    /// genuine labels while cutting the tail.
    var sceneClassificationMinConfidence: Float = 0.15

    /// How many of the highest-confidence labels to consider per image. Small on
    /// purpose — the further down the ranking a label sits, the more likely a
    /// keyword match is coincidence rather than content.
    var sceneClassificationTopLabels: Int = 5

    /// A label assigns a content category only when its confidence is at least
    /// this fraction of the photo's STRONGEST label.
    ///
    /// Separate from `sceneClassificationMinConfidence`, which governs which
    /// labels are stored for the "Why this photo?" sheet — a label worth showing
    /// (0.15+) is not necessarily one worth categorising on. A document the
    /// classifier was 90% sure of, carrying an incidental 38% "sky", was being
    /// filed under Nature: 0.38 is 42% of 0.90, below this floor, so the sky no
    /// longer counts. Relative rather than absolute because the classifier
    /// spreads confidence unevenly from photo to photo.
    var categoryConfidenceRelativeFloor: Float = 0.5

    /// …and never below this in absolute terms, so a photo whose top label is
    /// itself weak can't let an even weaker one through on the ratio alone.
    var categoryConfidenceAbsoluteFloor: Float = 0.3


    static let `default` = AnalysisConfiguration()
}
