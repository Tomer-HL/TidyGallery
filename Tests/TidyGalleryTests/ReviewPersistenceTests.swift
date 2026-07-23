//
//  ReviewPersistenceTests.swift
//  TidyGalleryTests
//
//  A user sorted 200+ duplicates, navigated back, and every choice was gone —
//  the review had reset to the scan's default suggestions. The cause was
//  ownership: `ReviewScreen` held its `ReviewModel` in `@State`, and as a
//  `NavigationLink` destination its `@State` is destroyed on pop and re-seeded
//  from defaults on return. The fix moves the model into the coordinator, which
//  outlives navigation.
//
//  The regression guard is instance stability: the coordinator must hand out
//  the SAME `ReviewModel` across accesses. Everything else follows — a returning
//  `ReviewScreen` reads the identical object, so every deletion tick and
//  best-shot change made through it is still there. If this `===` ever breaks,
//  the bug is back, whatever the UI layer looks like.
//
//  (Reset-on-rescan is driven from inside `scan()`, which needs photo access and
//  a device; it can't be exercised in a unit test, so it isn't asserted here.)
//

import Testing
import Foundation
import SwiftData
@testable import TidyGallery

@Suite("Review persistence")
@MainActor
struct ReviewPersistenceTests {

    /// A coordinator backed entirely by in-memory stores. Enough to exercise the
    /// review-model ownership without a photo library or a device.
    private func makeCoordinator() throws -> LibraryScanCoordinator {
        let cacheContainer = try ModelContainer(
            for: Schema([CachedAnalysis.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ignoreContainer = try ModelContainer(
            for: Schema([IgnoredAsset.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return LibraryScanCoordinator(
            library: PhotoLibraryService(),
            analyzer: ImageAnalyzer(),
            cache: AnalysisCacheStore(modelContainer: cacheContainer),
            ignoreList: IgnoreListStore(modelContainer: ignoreContainer),
            tuning: .default
        )
    }

    @Test("The coordinator hands out one stable review model")
    func modelInstanceIsStable() throws {
        let coordinator = try makeCoordinator()

        let first = coordinator.reviewModel
        let second = coordinator.reviewModel

        // `===`, not `==`: this is about object identity. A fresh model per
        // access is the old per-view `@State` behaviour merely relocated, and
        // would wipe edits on every navigation just the same. Once the identity
        // holds, "edits survive navigation" follows for free — a returning
        // screen mutates and reads the very same object — so there is nothing
        // further to assert that wouldn't just be restating `===`.
        #expect(first === second)
    }
}

/// `reconcile` is what keeps the shared model in step with stacks that change
/// under the user — a progressive scan, a re-cluster — WITHOUT resetting the
/// choices they've made. Testable directly on `ReviewModel`, no coordinator.
@Suite("Review reconcile")
@MainActor
struct ReviewReconcileTests {

    private func stack(_ id: String, members: [String], best: String, preselect: [String] = []) -> PhotoStack {
        PhotoStack(
            assets: members.map { PhotoAsset.make(id: $0) },
            bestShotID: best,
            rankedAssetIDs: members,
            assetsPreselectedForDeletion: Set(preselect)
        )
    }

    @Test("A user's edits survive stacks being rebuilt with fresh ids")
    func editsSurviveRebuild() {
        let model = ReviewModel(stacks: [stack("s", members: ["a", "b", "c"], best: "a")])
        let id = model.stacks[0].id

        // The user unticks the default and picks a different best shot.
        model.toggleDeletion(of: "b", inStack: id)
        model.setBestShot("c", inStack: id)

        // A rebuild: same photos, brand-new PhotoStack id and default suggestions
        // (best "a", nothing preselected) — exactly what buildStacks produces.
        model.reconcile(with: [stack("s2", members: ["a", "b", "c"], best: "a")])

        #expect(model.stacks.count == 1)
        #expect(model.stacks[0].bestShotID == "c", "the chosen best shot must survive")
        #expect(model.stacks[0].checkedForDeletion.contains("b"), "the deletion tick must survive")
    }

    @Test("New groups from a progressive scan are added without disturbing edits")
    func progressiveScanAddsGroups() {
        let model = ReviewModel(stacks: [stack("a", members: ["a1", "a2"], best: "a1")])
        model.toggleDeletion(of: "a2", inStack: model.stacks[0].id)

        // A later page brings a second group; the first is unchanged.
        model.reconcile(with: [
            stack("a", members: ["a1", "a2"], best: "a1"),
            stack("b", members: ["b1", "b2"], best: "b1", preselect: ["b2"])
        ])

        #expect(model.stacks.count == 2)
        // Edit on the pre-existing group preserved.
        #expect(model.assetsToDelete.contains("a2"))
        // New group carries its default suggestion.
        #expect(model.assetsToDelete.contains("b2"))
    }

    @Test("A group whose membership changed is reset to defaults")
    func changedMembershipResets() {
        // If the members differ, it is a different group as far as the user's
        // prior decision is concerned — carrying a stale tick could re-propose
        // a photo they'd chosen to keep.
        let model = ReviewModel(stacks: [stack("s", members: ["a", "b", "c"], best: "a")])
        model.toggleDeletion(of: "b", inStack: model.stacks[0].id)

        // "c" is gone; this is now a two-photo group with a default suggestion.
        model.reconcile(with: [stack("s2", members: ["a", "b"], best: "a", preselect: ["b"])])

        #expect(model.stacks.count == 1)
        #expect(model.stacks[0].checkedForDeletion == ["b"], "defaults apply to a changed group")
    }

    @Test("A group that disappears is dropped")
    func vanishedGroupIsDropped() {
        let model = ReviewModel(stacks: [
            stack("a", members: ["a1", "a2"], best: "a1"),
            stack("b", members: ["b1", "b2"], best: "b1")
        ])

        model.reconcile(with: [stack("a", members: ["a1", "a2"], best: "a1")])

        #expect(model.stacks.count == 1)
        #expect(model.stacks[0].assets.map(\.id) == ["a1", "a2"])
    }

    @Test("Reconciling to nothing empties the model")
    func reconcileToEmpty() {
        let model = ReviewModel(stacks: [stack("a", members: ["a1", "a2"], best: "a1")])
        model.reconcile(with: [])
        #expect(model.stacks.isEmpty)
    }
}
