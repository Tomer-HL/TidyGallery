//
//  CachedAnalysis.swift
//  TidyGallery
//
//  SwiftData model that caches expensive per-asset analysis so we only ever
//  compute a photo's feature print + score ONCE. Re-analysis is triggered only
//  when the asset's `modificationDate` changes (edit, favorite toggle) or when
//  a `PHPhotoLibraryChangeObserver` reports it inserted.
//

import Foundation
import SwiftData

/// Persisted analysis for a single asset, keyed by `PHAsset.localIdentifier`.
///
/// We store the feature-print vector and the score components as encoded blobs
/// rather than exploding them into columns — they're only ever read/written as
/// a unit, and this keeps the schema tiny and migration-friendly.
@Model
final class CachedAnalysis {

    /// Bumped whenever the analysis pipeline gains a new output that older cache
    /// rows won't have. A row from an earlier version is treated as stale so the
    /// asset is re-analysed once, back-filling the new data.
    ///   v1 → feature print + score
    ///   v2 → adds on-device scene tags (food / pets / documents)
    ///   v3 → adds nature (classifier) + selfies (face geometry) tags
    ///   v4 → classifier sensitivity fix (top-N labels over a low floor) and a
    ///        much wider keyword map, so scene tags must be recomputed
    ///   v5 → tightened confidence + pruned keywords, face veto on Documents,
    ///        and selfies moved to the system smart album
    static let currentSchemaVersion = 5

    /// `PHAsset.localIdentifier`. Unique so we can upsert by identity.
    @Attribute(.unique) var localIdentifier: String

    /// The asset's modification date at the time we analysed it. If the live
    /// asset's modification date differs, the cache entry is stale.
    var analysedModificationDate: Date?

    /// JSON-encoded `FeaturePrint`.
    var featurePrintData: Data

    /// JSON-encoded `ShotScore`.
    var scoreData: Data

    /// JSON-encoded `[SceneCategory]`. Optional so existing rows migrate cleanly;
    /// `nil` rows are older-version and will be re-analysed.
    var sceneTagsData: Data?

    /// Which pipeline version produced this row (see `currentSchemaVersion`).
    /// Defaulted so pre-existing rows migrate to 0 and are refreshed.
    var schemaVersion: Int = 0

    /// When this cache row was written (for optional TTL/debugging).
    var updatedAt: Date

    init(
        localIdentifier: String,
        analysedModificationDate: Date?,
        featurePrintData: Data,
        scoreData: Data,
        sceneTagsData: Data?,
        schemaVersion: Int,
        updatedAt: Date = .now
    ) {
        self.localIdentifier = localIdentifier
        self.analysedModificationDate = analysedModificationDate
        self.featurePrintData = featurePrintData
        self.scoreData = scoreData
        self.sceneTagsData = sceneTagsData
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
    }
}

// MARK: - Encoding helpers

extension CachedAnalysis {

    /// Build a cache row from decoded values.
    static func make(
        localIdentifier: String,
        modificationDate: Date?,
        featurePrint: FeaturePrint,
        score: ShotScore,
        sceneTags: Set<SceneCategory>
    ) throws -> CachedAnalysis {
        let encoder = JSONEncoder()
        return CachedAnalysis(
            localIdentifier: localIdentifier,
            analysedModificationDate: modificationDate,
            featurePrintData: try encoder.encode(featurePrint),
            scoreData: try encoder.encode(score),
            sceneTagsData: try encoder.encode(Array(sceneTags)),
            schemaVersion: currentSchemaVersion
        )
    }

    /// Decode the stored feature print, or `nil` if the blob is corrupt.
    func decodedFeaturePrint() -> FeaturePrint? {
        try? JSONDecoder().decode(FeaturePrint.self, from: featurePrintData)
    }

    /// Decode the stored score, or `nil` if the blob is corrupt.
    func decodedScore() -> ShotScore? {
        try? JSONDecoder().decode(ShotScore.self, from: scoreData)
    }

    /// Decode the stored scene tags (empty when absent or corrupt).
    func decodedSceneTags() -> Set<SceneCategory> {
        guard let sceneTagsData,
              let array = try? JSONDecoder().decode([SceneCategory].self, from: sceneTagsData)
        else { return [] }
        return Set(array)
    }

    /// Whether this cached row is still valid for an asset with the given
    /// modification date — the modification date must match AND the row must
    /// come from the current pipeline version.
    func isFresh(for modificationDate: Date?) -> Bool {
        analysedModificationDate == modificationDate
            && schemaVersion == Self.currentSchemaVersion
    }
}
