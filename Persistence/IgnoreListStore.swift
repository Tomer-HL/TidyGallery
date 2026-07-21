//
//  IgnoreListStore.swift
//  TidyGallery
//
//  Serialised, `Sendable` gateway to the user's ignore list. Mirrors
//  `AnalysisCacheStore`: a `@ModelActor` keeps `ModelContext` access off the
//  main thread, and only value types cross the boundary.
//

import Foundation
import SwiftData

@ModelActor
actor IgnoreListStore {

    /// Every ignored asset identifier.
    func allIgnoredIDs() throws -> Set<String> {
        let rows = try modelContext.fetch(FetchDescriptor<IgnoredAsset>())
        return Set(rows.map(\.localIdentifier))
    }

    /// Mark assets as ignored. Idempotent — existing rows are left alone.
    func ignore(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let existing = try allIgnoredIDs()
        for id in ids where !existing.contains(id) {
            modelContext.insert(IgnoredAsset(localIdentifier: id))
        }
        try modelContext.save()
    }

    /// Stop ignoring assets (they become eligible for suggestions again).
    func unignore(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        let rows = try modelContext.fetch(FetchDescriptor<IgnoredAsset>())
        for row in rows where wanted.contains(row.localIdentifier) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// Drop ignore entries for assets that no longer exist, so the table doesn't
    /// grow unbounded as the library changes.
    func purge(ids: [String]) throws {
        try unignore(ids: ids)
    }
}
