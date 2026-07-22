//
//  RecordingFlagStore.swift
//  TidyGallery
//
//  A `ModelActor` owning reads/writes to the screen-recording cache, mirroring
//  `AssetSizeCacheStore`: `Sendable` value types in and out, never a `@Model`.
//

import Foundation
import SwiftData

/// Serialised, `Sendable` gateway to the screen-recording cache.
@ModelActor
actor RecordingFlagStore {

    /// Known recording flags for a batch of videos, in one query.
    ///
    /// - Returns: `localIdentifier -> isScreenRecording` for every id already
    ///   known. Absent means "never walked", not "not a recording" — the
    ///   distinction matters, because `false` is a real cached answer worth
    ///   keeping. Around 90% of videos are not screen recordings, so treating a
    ///   negative as a cache miss would leave almost the entire cost in place.
    func flags(for identifiers: [String]) throws -> [String: Bool] {
        guard !identifiers.isEmpty else { return [:] }

        let ids = identifiers
        let descriptor = FetchDescriptor<CachedRecordingFlag>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        )
        var result: [String: Bool] = [:]
        // `isFresh` compares against the detection rule's version, not the
        // asset's state — a row written by an older rule is re-derived once.
        for row in try modelContext.fetch(descriptor) where row.isFresh {
            result[row.localIdentifier] = row.isScreenRecording
        }
        return result
    }

    /// One video's answer, ready to persist.
    struct Entry: Sendable {
        let id: String
        let isScreenRecording: Bool

        init(id: String, isScreenRecording: Bool) {
            self.id = id
            self.isScreenRecording = isScreenRecording
        }
    }

    /// Upsert a batch in one transaction, for the same reason the other stores
    /// batch: a per-asset fetch-and-save would cost more than the walk it saves.
    func storeBatch(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return }

        let ids = entries.map(\.id)
        let descriptor = FetchDescriptor<CachedRecordingFlag>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }

        for entry in entries {
            modelContext.insert(
                CachedRecordingFlag(
                    localIdentifier: entry.id,
                    isScreenRecording: entry.isScreenRecording
                )
            )
        }
        try modelContext.save()
    }

    /// Drop rows for assets that no longer exist, so the cache doesn't grow
    /// without bound as the user deletes videos.
    func purge(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let descriptor = FetchDescriptor<CachedRecordingFlag>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// Discard everything. The escape hatch for a bad detection rule — sizes and
    /// analysis both have one, and this cache has no per-asset staleness rule to
    /// fall back on, so it needs this more than they do.
    func purgeAll() throws {
        for row in try modelContext.fetch(FetchDescriptor<CachedRecordingFlag>()) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// How many rows are held. Diagnostics and tests only.
    func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<CachedRecordingFlag>())
    }
}
