//
//  AssetSizeCacheTests.swift
//  TidyGalleryTests
//
//  The size cache exists to stop paying ~9 ms per asset on every launch. That
//  saving is only legitimate if the freshness rule is exactly right: a cache
//  that returns a size for a photo that has since been edited will understate or
//  overstate reclaimable space, and the user makes deletion decisions on those
//  numbers. Too eager is a correctness bug; too conservative is only a
//  performance one.
//
//  These tests run against a real in-memory SwiftData store — the model layer is
//  the thing under test, so mocking it would test nothing.
//

import Testing
import Foundation
import SwiftData
@testable import TidyGallery

@Suite("Asset size cache")
struct AssetSizeCacheTests {

    /// A fresh, isolated in-memory store per test.
    private func makeStore() throws -> AssetSizeCacheStore {
        let container = try ModelContainer(
            for: Schema([CachedAssetSize.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return AssetSizeCacheStore(modelContainer: container)
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Round trip

    @Test("A stored size comes back for the same modification date")
    func roundTrip() async throws {
        let store = try makeStore()
        try await store.storeBatch([.init(id: "A", modificationDate: epoch, bytes: 4_096)])

        let hit = try await store.sizes(for: [AssetIdentity(id: "A", modificationDate: epoch)])
        #expect(hit["A"] == 4_096)
    }

    @Test("An unknown asset is simply absent, never zero")
    func unknownIsAbsent() async throws {
        let store = try makeStore()
        let result = try await store.sizes(for: [AssetIdentity(id: "ghost", modificationDate: epoch)])

        // Absent, not present-as-zero: a zero would be summed into the
        // dashboard's reclaimable total as a real measurement of nothing.
        #expect(result["ghost"] == nil)
        #expect(result.isEmpty)
    }

    // MARK: Staleness — the part that must not be wrong

    @Test("An edited asset (new modification date) is treated as stale")
    func modificationDateInvalidates() async throws {
        let store = try makeStore()
        try await store.storeBatch([.init(id: "A", modificationDate: epoch, bytes: 4_096)])

        let edited = epoch.addingTimeInterval(60)
        let result = try await store.sizes(for: [AssetIdentity(id: "A", modificationDate: edited)])

        #expect(result.isEmpty, "An edit adds an adjusted resource — the old size is wrong.")
    }

    @Test("nil and non-nil modification dates are not interchangeable")
    func nilDateIsDistinct() async throws {
        let store = try makeStore()
        try await store.storeBatch([.init(id: "A", modificationDate: nil, bytes: 4_096)])

        let withDate = try await store.sizes(for: [AssetIdentity(id: "A", modificationDate: epoch)])
        let withoutDate = try await store.sizes(for: [AssetIdentity(id: "A", modificationDate: nil)])

        #expect(withDate.isEmpty)
        #expect(withoutDate["A"] == 4_096)
    }

    @Test("A row from an older measurement version is stale")
    func schemaVersionInvalidates() async throws {
        let container = try ModelContainer(
            for: Schema([CachedAssetSize.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        // Write a row as an older build would have.
        let context = ModelContext(container)
        context.insert(
            CachedAssetSize(
                localIdentifier: "A",
                measuredModificationDate: epoch,
                bytes: 4_096,
                schemaVersion: CachedAssetSize.currentSchemaVersion - 1
            )
        )
        try context.save()

        let store = AssetSizeCacheStore(modelContainer: container)
        let result = try await store.sizes(for: [AssetIdentity(id: "A", modificationDate: epoch)])
        #expect(result.isEmpty, "A version bump must force a re-measure, not serve old numbers.")
    }

    // MARK: Partial hits — the normal case after the first scan

    @Test("A mixed batch returns only the fresh entries, so the caller measures the difference")
    func partialHit() async throws {
        let store = try makeStore()
        try await store.storeBatch([
            .init(id: "fresh", modificationDate: epoch, bytes: 100),
            .init(id: "stale", modificationDate: epoch, bytes: 200)
        ])

        let result = try await store.sizes(for: [
            AssetIdentity(id: "fresh", modificationDate: epoch),
            AssetIdentity(id: "stale", modificationDate: epoch.addingTimeInterval(1)),
            AssetIdentity(id: "new", modificationDate: epoch)
        ])

        #expect(result.count == 1)
        #expect(result["fresh"] == 100)
        #expect(result["stale"] == nil)
        #expect(result["new"] == nil)
    }

    @Test("An empty request does no work and returns nothing")
    func emptyRequest() async throws {
        let store = try makeStore()
        let result = try await store.sizes(for: [])
        #expect(result.isEmpty)
        try await store.storeBatch([])   // must not throw
    }

    // MARK: Upsert

    @Test("Re-storing an id replaces the row rather than duplicating it")
    func upsertReplaces() async throws {
        let store = try makeStore()
        let later = epoch.addingTimeInterval(60)

        try await store.storeBatch([.init(id: "A", modificationDate: epoch, bytes: 100)])
        try await store.storeBatch([.init(id: "A", modificationDate: later, bytes: 999)])

        let rows = try await store.count()
        let result = try await store.sizes(for: [AssetIdentity(id: "A", modificationDate: later)])

        #expect(rows == 1, "@Attribute(.unique) plus a delete-then-insert upsert.")
        #expect(result["A"] == 999)
    }

    // MARK: Purging

    @Test("Purging deleted assets removes their rows and leaves the rest")
    func purgeRemovesOnlyNamedRows() async throws {
        let store = try makeStore()
        try await store.storeBatch([
            .init(id: "gone", modificationDate: epoch, bytes: 1),
            .init(id: "kept", modificationDate: epoch, bytes: 2)
        ])

        try await store.purge(ids: ["gone"])

        let rows = try await store.count()
        let result = try await store.sizes(for: [AssetIdentity(id: "kept", modificationDate: epoch)])

        #expect(rows == 1)
        #expect(result["kept"] == 2)
    }

    @Test("purgeAll empties the store")
    func purgeAllEmpties() async throws {
        let store = try makeStore()
        try await store.storeBatch([
            .init(id: "A", modificationDate: epoch, bytes: 1),
            .init(id: "B", modificationDate: epoch, bytes: 2)
        ])

        try await store.purgeAll()
        let rows = try await store.count()
        #expect(rows == 0)
    }

    // MARK: The completeness contract

    @Test("A measurement is complete unless something explicitly says otherwise")
    func measurementDefaultsToComplete() {
        // Callers that filter on size treat `isComplete == false` as "no answer"
        // and keep their previous list. If this default ever flipped, those
        // categories would silently stop updating — a failure with no symptom
        // beyond stale data, so it is worth a test of its own.
        let empty = PhotoLibraryService.SizeMeasurement()
        #expect(empty.isComplete)
        #expect(empty.sizes.isEmpty)
        #expect(empty.fromCache == 0)
        #expect(empty.measured == 0)
        #expect(empty.measuredSeconds == 0)
    }

    // MARK: Scale

    @Test("A batch larger than the service's chunk size round-trips intact")
    func largeBatch() async throws {
        let store = try makeStore()
        let entries = (0..<1_200).map {
            AssetSizeCacheStore.Entry(id: "asset-\($0)", modificationDate: epoch, bytes: Int64($0))
        }
        try await store.storeBatch(entries)

        let identities = entries.map { AssetIdentity(id: $0.id, modificationDate: epoch) }
        let result = try await store.sizes(for: identities)

        #expect(result.count == 1_200)
        #expect(result["asset-0"] == 0)
        #expect(result["asset-1199"] == 1_199)
    }
}
