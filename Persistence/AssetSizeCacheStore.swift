//
//  AssetSizeCacheStore.swift
//  TidyGallery
//
//  A `ModelActor` owning all reads/writes to the on-disk size cache, mirroring
//  `AnalysisCacheStore`: callers pass `Sendable` value types in and get value
//  types out, never a `@Model` object (models are bound to their context and
//  are not `Sendable`).
//

import Foundation
import SwiftData

/// The identity a size measurement is keyed on. `Sendable` on purpose: this is
/// what crosses between `PhotoLibraryService` and this actor, so no `PHAsset`
/// or `PHFetchResult` ever has to.
struct AssetIdentity: Sendable, Equatable {
    let id: String
    let modificationDate: Date?

    init(id: String, modificationDate: Date?) {
        self.id = id
        self.modificationDate = modificationDate
    }
}

/// Serialised, `Sendable` gateway to the asset size cache.
@ModelActor
actor AssetSizeCacheStore {

    /// Fresh cached sizes for a batch of assets, in one query.
    ///
    /// - Returns: `localIdentifier -> bytes` for entries that are present AND
    ///   fresh for the supplied modification date. Missing and stale assets are
    ///   simply absent, so the caller measures exactly the difference.
    func sizes(for identities: [AssetIdentity]) throws -> [String: Int64] {
        guard !identities.isEmpty else { return [:] }

        let ids = identities.map(\.id)
        let descriptor = FetchDescriptor<CachedAssetSize>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        )
        let rows = try modelContext.fetch(descriptor)

        // Index the caller's modification dates for the freshness check.
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter
        // traps on a duplicate id. Callers pass deduplicated sets today, but a
        // crash is a steep price for that assumption ever changing.
        let modDates = Dictionary(
            identities.map { ($0.id, $0.modificationDate) },
            uniquingKeysWith: { _, latest in latest }
        )

        var result: [String: Int64] = [:]
        for row in rows where row.isFresh(for: modDates[row.localIdentifier] ?? nil) {
            result[row.localIdentifier] = row.bytes
        }
        return result
    }

    /// One asset's measured size, ready to persist.
    struct Entry: Sendable {
        let id: String
        let modificationDate: Date?
        let bytes: Int64

        init(id: String, modificationDate: Date?, bytes: Int64) {
            self.id = id
            self.modificationDate = modificationDate
            self.bytes = bytes
        }
    }

    /// Upsert a batch of measurements in **one** transaction.
    ///
    /// Batched for the same reason `AnalysisCacheStore.storeBatch` is: a
    /// per-asset fetch-and-save would mean 20,000 queries and 20,000 disk writes
    /// on a first scan, which would cost more than the measuring it is meant to
    /// save.
    func storeBatch(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return }

        // Clear any existing rows for these ids in a single query.
        let ids = entries.map(\.id)
        let descriptor = FetchDescriptor<CachedAssetSize>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }

        for entry in entries {
            modelContext.insert(
                CachedAssetSize(
                    localIdentifier: entry.id,
                    measuredModificationDate: entry.modificationDate,
                    bytes: entry.bytes
                )
            )
        }
        try modelContext.save()   // one write for the whole batch
    }

    /// Delete rows for assets that no longer exist in the library, so the cache
    /// doesn't grow unbounded as the user cleans up.
    func purge(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let descriptor = FetchDescriptor<CachedAssetSize>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// Discard everything. Sizes are a pure optimisation — never user data — so
    /// this only ever costs a re-measure.
    func purgeAll() throws {
        for row in try modelContext.fetch(FetchDescriptor<CachedAssetSize>()) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// How many rows are held. Diagnostics only.
    func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<CachedAssetSize>())
    }
}
