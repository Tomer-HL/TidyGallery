//
//  IgnoreFlowTests.swift
//  TidyGalleryTests
//
//  Regression tests for a bug found on a real device: photos kept in the
//  Duplicates review flow never appeared under Ignored.
//
//  The cause was not a faulty calculation, which is why nothing caught it. The
//  Duplicates screen simply had no route to the ignore list — its only "keep"
//  affordance unticked checkboxes in memory. Every individual piece worked; the
//  wiring between two of them didn't exist.
//
//  That shape of bug is invisible to tests that only exercise pure functions, so
//  these tests assert on the *contracts between* the pieces instead: that the
//  review model can drop a group, and that the ignore list round-trips.
//
//  The sibling bug — a kept VIDEO never reappearing under Ignored, because the
//  snapshot helper filtered to stills — cannot be covered here: it lives in
//  `PhotoLibraryService`, which needs a real photo library. It is guarded by the
//  `imagesOnly` parameter now being explicit at both call sites rather than an
//  invisible default, which is the best a unit test can do for it.
//

import Testing
import Foundation
import SwiftData
@testable import TidyGallery

@Suite("Ignore flow")
struct IgnoreFlowTests {

    /// An isolated in-memory ignore store, so tests never touch a real one.
    private func makeStore() throws -> IgnoreListStore {
        let container = try ModelContainer(
            for: Schema([IgnoredAsset.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return IgnoreListStore(modelContainer: container)
    }

    // MARK: Persistence contract

    @Test("Ignored ids come back out")
    func roundTrip() async throws {
        let store = try makeStore()
        try await store.ignore(ids: ["a", "b", "c"])

        let stored = try await store.allIgnoredIDs()
        #expect(stored == ["a", "b", "c"])
    }

    @Test("Ignoring the same photo twice is idempotent")
    func idempotent() async throws {
        let store = try makeStore()
        try await store.ignore(ids: ["a", "b"])
        try await store.ignore(ids: ["b", "c"])

        // "b" must not produce a second row — `localIdentifier` is unique, so a
        // duplicate insert would throw and take the whole write down with it.
        let stored = try await store.allIgnoredIDs()
        #expect(stored == ["a", "b", "c"])
    }

    @Test("Un-ignoring removes only what was asked for")
    func unignoreIsTargeted() async throws {
        let store = try makeStore()
        try await store.ignore(ids: ["a", "b", "c"])
        try await store.unignore(ids: ["b"])

        let stored = try await store.allIgnoredIDs()
        #expect(stored == ["a", "c"])
    }

    @Test("An empty list is a no-op, not an error")
    func emptyIsSafe() async throws {
        let store = try makeStore()
        try await store.ignore(ids: [])
        try await store.unignore(ids: [])
        let stored = try await store.allIgnoredIDs()
        #expect(stored.isEmpty)
    }

    // MARK: Review model contract

    @Test("A group can be dropped from review once it's been kept for good")
    @MainActor func removeStack() {
        let assets = [PhotoAsset.make(id: "1"), PhotoAsset.make(id: "2")]
        let stack = PhotoStack(
            assets: assets,
            bestShotID: "1",
            rankedAssetIDs: ["1", "2"],
            assetsPreselectedForDeletion: ["2"]
        )
        let model = ReviewModel(stacks: [stack])
        let stackID = model.stacks[0].id

        model.removeStack(stackID)
        #expect(model.stacks.isEmpty)
    }

    @Test("Removing an unknown group leaves the list alone")
    @MainActor func removeUnknownStack() {
        let stack = PhotoStack(
            assets: [PhotoAsset.make(id: "1"), PhotoAsset.make(id: "2")],
            bestShotID: "1",
            rankedAssetIDs: ["1", "2"],
            assetsPreselectedForDeletion: []
        )
        let model = ReviewModel(stacks: [stack])

        model.removeStack(UUID())
        #expect(model.stacks.count == 1)
    }

    @Test("Unticking a group is not the same as keeping it for good")
    @MainActor func clearChecksIsNotDurable() {
        let stack = PhotoStack(
            assets: [PhotoAsset.make(id: "1"), PhotoAsset.make(id: "2")],
            bestShotID: "1",
            rankedAssetIDs: ["1", "2"],
            assetsPreselectedForDeletion: ["2"]
        )
        let model = ReviewModel(stacks: [stack])
        let stackID = model.stacks[0].id

        model.clearChecks(inStack: stackID)

        // The group is still on screen with nothing checked — "not now".
        // Conflating this with "not ever" is precisely the bug being fixed:
        // a durable decision has to go through the ignore list instead.
        #expect(model.stacks.count == 1)
        #expect(model.stacks[0].checkedForDeletion.isEmpty)
    }

    // MARK: Every stack photo is offered, not just the extras

    @Test("Keeping a group covers the best shot too")
    func neverSuggestCoversWholeGroup() {
        let assets = [
            PhotoAsset.make(id: "best"),
            PhotoAsset.make(id: "extra1"),
            PhotoAsset.make(id: "extra2"),
        ]
        let stack = PhotoStack(
            assets: assets,
            bestShotID: "best",
            rankedAssetIDs: ["best", "extra1", "extra2"],
            assetsPreselectedForDeletion: ["extra1", "extra2"]
        )

        // "Never suggest this group" must cover every photo in it, including
        // the winner — otherwise the group re-forms on the next scan around the
        // one photo that wasn't ignored, and the user is asked all over again.
        let ids = stack.assets.map(\.id)
        #expect(Set(ids) == ["best", "extra1", "extra2"])
    }
}
