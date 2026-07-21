//
//  AnalysisCacheStore.swift
//  TidyGallery
//
//  A `ModelActor` that owns all reads/writes to the SwiftData cache. Using a
//  ModelActor keeps `ModelContext` access serialised and off the main thread,
//  and gives us a clean `Sendable` boundary: callers pass identifiers and
//  value types in, and get value types (never `@Model` objects) back.
//

import Foundation
import SwiftData

/// Serialised, `Sendable` gateway to the analysis cache.
///
/// Never hand a `CachedAnalysis` (a `@Model`) out of this actor — models are
/// bound to their context and aren't `Sendable`. We decode to value types
/// inside the actor and return those.
@ModelActor
actor AnalysisCacheStore {

    /// Fetch fresh cached analysis for a batch of assets in one query.
    ///
    /// - Returns: a dictionary of `localIdentifier -> AnalyzedImage` containing
    ///   only entries that are present AND fresh for the supplied modification
    ///   date and current pipeline version. Missing/stale assets are absent.
    func freshAnalysis(
        for assets: [(id: String, modificationDate: Date?)]
    ) throws -> [String: AnalyzedImage] {

        let ids = assets.map(\.id)
        let descriptor = FetchDescriptor<CachedAnalysis>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        )
        let rows = try modelContext.fetch(descriptor)

        // Index the caller's modification dates for a freshness check.
        let modDates = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.modificationDate) })

        var result: [String: AnalyzedImage] = [:]
        for row in rows {
            guard row.isFresh(for: modDates[row.localIdentifier] ?? nil),
                  let print = row.decodedFeaturePrint(),
                  let score = row.decodedScore()
            else { continue }
            result[row.localIdentifier] = AnalyzedImage(
                featurePrint: print,
                score: score,
                sceneTags: row.decodedSceneTags(),
                labels: row.decodedLabels()
            )
        }
        return result
    }

    /// One asset's analysis, ready to persist.
    struct Entry: Sendable {
        let id: String
        let modificationDate: Date?
        let featurePrint: FeaturePrint
        let score: ShotScore
        let sceneTags: Set<SceneCategory>
        let labels: [ClassificationLabel]
    }

    /// Upsert a whole page of results in **one** transaction.
    ///
    /// This matters a lot: the per-asset `store` below issues a fetch *and* a
    /// `save()` for every photo, so scanning a 20k library meant 20k queries and
    /// 20k disk writes. Batching collapses that to one query and one write per
    /// page, which is the single biggest win in the scan pipeline.
    func storeBatch(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return }

        // Clear any existing rows for these ids in a single query.
        let ids = entries.map(\.id)
        let descriptor = FetchDescriptor<CachedAnalysis>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }

        for entry in entries {
            modelContext.insert(
                try CachedAnalysis.make(
                    localIdentifier: entry.id,
                    modificationDate: entry.modificationDate,
                    featurePrint: entry.featurePrint,
                    score: entry.score,
                    sceneTags: entry.sceneTags,
                    labels: entry.labels
                )
            )
        }
        try modelContext.save()   // one write for the whole page
    }

    /// Upsert one asset's analysis. Replaces any existing row for the id.
    func store(
        id: String,
        modificationDate: Date?,
        featurePrint: FeaturePrint,
        score: ShotScore,
        sceneTags: Set<SceneCategory>,
        labels: [ClassificationLabel]
    ) throws {
        // Remove a stale row if present, then insert fresh.
        let descriptor = FetchDescriptor<CachedAnalysis>(
            predicate: #Predicate { $0.localIdentifier == id }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
        }
        let row = try CachedAnalysis.make(
            localIdentifier: id,
            modificationDate: modificationDate,
            featurePrint: featurePrint,
            score: score,
            sceneTags: sceneTags,
            labels: labels
        )
        modelContext.insert(row)
        try modelContext.save()
    }

    /// Discard the entire cache. Used when analysis settings change, since every
    /// stored result was produced under the previous settings. The cache is a
    /// pure optimisation, so this only costs a re-scan — never user data.
    func purgeAll() throws {
        for row in try modelContext.fetch(FetchDescriptor<CachedAnalysis>()) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// Delete cache rows for assets that no longer exist in the library.
    /// Called when the change observer reports deletions, to keep the cache
    /// from growing unbounded.
    func purge(ids: [String]) throws {
        let descriptor = FetchDescriptor<CachedAnalysis>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }
}
