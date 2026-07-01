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
    /// - Returns: a dictionary of `localIdentifier -> (FeaturePrint, ShotScore)`
    ///   containing only entries that are present AND fresh for the supplied
    ///   modification date. Missing/stale assets are simply absent.
    func freshAnalysis(
        for assets: [(id: String, modificationDate: Date?)]
    ) throws -> [String: (FeaturePrint, ShotScore)] {

        let ids = assets.map(\.id)
        let descriptor = FetchDescriptor<CachedAnalysis>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        )
        let rows = try modelContext.fetch(descriptor)

        // Index the caller's modification dates for a freshness check.
        let modDates = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.modificationDate) })

        var result: [String: (FeaturePrint, ShotScore)] = [:]
        for row in rows {
            guard row.isFresh(for: modDates[row.localIdentifier] ?? nil),
                  let print = row.decodedFeaturePrint(),
                  let score = row.decodedScore()
            else { continue }
            result[row.localIdentifier] = (print, score)
        }
        return result
    }

    /// Upsert one asset's analysis. Replaces any existing row for the id.
    func store(
        id: String,
        modificationDate: Date?,
        featurePrint: FeaturePrint,
        score: ShotScore
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
            score: score
        )
        modelContext.insert(row)
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
