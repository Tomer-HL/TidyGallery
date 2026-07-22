//
//  RecordingFlagCacheTests.swift
//  TidyGalleryTests
//
//  The screen-recording cache removes 97% of the metadata pass — the cost the
//  device measurement identified as the last uncached thing paid on every
//  launch. These pin the two properties that make that saving legitimate:
//  a cached `false` is a real answer, and a row survives anything except the
//  asset itself going away.
//

import Testing
import Foundation
import SwiftData
@testable import TidyGallery

@Suite("Screen-recording cache")
struct RecordingFlagCacheTests {

    private func makeStore() throws -> RecordingFlagStore {
        let container = try ModelContainer(
            for: Schema([CachedRecordingFlag.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return RecordingFlagStore(modelContainer: container)
    }

    @Test("A stored flag comes back")
    func roundTrip() async throws {
        let store = try makeStore()
        try await store.storeBatch([
            .init(id: "recording", isScreenRecording: true),
            .init(id: "holiday", isScreenRecording: false)
        ])

        let flags = try await store.flags(for: ["recording", "holiday"])
        #expect(flags["recording"] == true)
        #expect(flags["holiday"] == false)
    }

    @Test("A cached 'not a recording' is a hit, not a miss")
    func negativesAreCached() async throws {
        // This is the property the whole saving rests on. Roughly nine in ten
        // videos are ordinary videos, so if `false` were treated as "unknown"
        // the walk would still run for almost every asset and the cache would
        // buy nearly nothing.
        let store = try makeStore()
        try await store.storeBatch([.init(id: "holiday", isScreenRecording: false)])

        let flags = try await store.flags(for: ["holiday"])
        #expect(flags["holiday"] != nil, "absent would mean 'walk it again'")
        #expect(flags["holiday"] == false)
    }

    @Test("An unknown video is absent, so the caller knows to walk it")
    func unknownIsAbsent() async throws {
        let store = try makeStore()
        let flags = try await store.flags(for: ["never-seen"])
        #expect(flags["never-seen"] == nil)
        #expect(flags.isEmpty)
    }

    @Test("A mixed batch returns only what is known")
    func partialHit() async throws {
        let store = try makeStore()
        try await store.storeBatch([.init(id: "known", isScreenRecording: true)])

        let flags = try await store.flags(for: ["known", "new"])
        #expect(flags.count == 1)
        #expect(flags["known"] == true)
        #expect(flags["new"] == nil)
    }

    @Test("No modification date is involved — the answer cannot go stale")
    func flagHasNoStalenessRule() async throws {
        // A video's original filename is fixed at capture. Editing adds an
        // adjusted resource without renaming the original, and identifiers are
        // never reused — so unlike the size cache there is nothing to compare
        // against. Storing it beside the size row would have inherited that
        // row's modificationDate rule and thrown the answer away whenever the
        // user favourited a video.
        let store = try makeStore()
        try await store.storeBatch([.init(id: "A", isScreenRecording: true)])

        // Same id, asked for repeatedly, with no date supplied anywhere.
        for _ in 0..<3 {
            let flags = try await store.flags(for: ["A"])
            #expect(flags["A"] == true)
        }
    }

    @Test("A row from an older detection rule is re-derived, not trusted")
    func schemaVersionInvalidates() async throws {
        // The asset can't go stale, but our rule can. Without this the day the
        // heuristic broadens past "RPReplay" every installed copy would keep
        // its old answers forever, with no way to invalidate them.
        let container = try ModelContainer(
            for: Schema([CachedRecordingFlag.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.insert(
            CachedRecordingFlag(
                localIdentifier: "A",
                isScreenRecording: true,
                schemaVersion: CachedRecordingFlag.currentSchemaVersion - 1
            )
        )
        try context.save()

        let store = RecordingFlagStore(modelContainer: container)
        let flags = try await store.flags(for: ["A"])
        #expect(flags.isEmpty, "an old-rule row must read as unknown, so it gets walked again")
    }

    @Test("purgeAll empties the store")
    func purgeAllEmpties() async throws {
        let store = try makeStore()
        try await store.storeBatch([
            .init(id: "A", isScreenRecording: true),
            .init(id: "B", isScreenRecording: false)
        ])
        try await store.purgeAll()
        let rows = try await store.count()
        #expect(rows == 0)
    }

    @Test("Re-storing replaces rather than duplicating")
    func upsertReplaces() async throws {
        let store = try makeStore()
        try await store.storeBatch([.init(id: "A", isScreenRecording: false)])
        try await store.storeBatch([.init(id: "A", isScreenRecording: true)])

        let rows = try await store.count()
        let flags = try await store.flags(for: ["A"])
        #expect(rows == 1)
        #expect(flags["A"] == true)
    }

    @Test("Purging a deleted video removes its row and leaves the rest")
    func purgeRemovesOnlyNamedRows() async throws {
        let store = try makeStore()
        try await store.storeBatch([
            .init(id: "gone", isScreenRecording: true),
            .init(id: "kept", isScreenRecording: false)
        ])

        try await store.purge(ids: ["gone"])

        let rows = try await store.count()
        let flags = try await store.flags(for: ["kept"])
        #expect(rows == 1)
        #expect(flags["kept"] == false)
    }

    @Test("Empty input does no work")
    func emptyInput() async throws {
        let store = try makeStore()
        let flags = try await store.flags(for: [])
        #expect(flags.isEmpty)
        try await store.storeBatch([])
        try await store.purge(ids: [])
        let rows = try await store.count()
        #expect(rows == 0)
    }

    @Test("A realistic library round-trips intact")
    func largeBatch() async throws {
        let store = try makeStore()
        // Proportions from the device run: 1,526 videos, a minority of which
        // are recordings.
        let entries = (0..<1_526).map {
            RecordingFlagStore.Entry(id: "video-\($0)", isScreenRecording: $0 % 10 == 0)
        }
        try await store.storeBatch(entries)

        let flags = try await store.flags(for: entries.map(\.id))
        #expect(flags.count == 1_526)
        #expect(flags["video-0"] == true)
        #expect(flags["video-1"] == false)
        #expect(flags.values.filter { $0 }.count == 153)
    }
}
