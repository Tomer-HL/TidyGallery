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

    /// `PHAsset.localIdentifier`. Unique so we can upsert by identity.
    @Attribute(.unique) var localIdentifier: String

    /// The asset's modification date at the time we analysed it. If the live
    /// asset's modification date differs, the cache entry is stale.
    var analysedModificationDate: Date?

    /// JSON-encoded `FeaturePrint`.
    var featurePrintData: Data

    /// JSON-encoded `ShotScore`.
    var scoreData: Data

    /// When this cache row was written (for optional TTL/debugging).
    var updatedAt: Date

    init(
        localIdentifier: String,
        analysedModificationDate: Date?,
        featurePrintData: Data,
        scoreData: Data,
        updatedAt: Date = .now
    ) {
        self.localIdentifier = localIdentifier
        self.analysedModificationDate = analysedModificationDate
        self.featurePrintData = featurePrintData
        self.scoreData = scoreData
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
        score: ShotScore
    ) throws -> CachedAnalysis {
        let encoder = JSONEncoder()
        return CachedAnalysis(
            localIdentifier: localIdentifier,
            analysedModificationDate: modificationDate,
            featurePrintData: try encoder.encode(featurePrint),
            scoreData: try encoder.encode(score)
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

    /// Whether this cached row is still valid for an asset with the given
    /// modification date.
    func isFresh(for modificationDate: Date?) -> Bool {
        analysedModificationDate == modificationDate
    }
}
