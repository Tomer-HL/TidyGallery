//
//  SafetyInvariantTests.swift
//  TidyGalleryTests
//
//  These are the most important tests in the project. They guard the promises
//  the whole product rests on:
//    • A favorite is NEVER pre-selected for deletion.
//    • Pre-selection is conservative: a photo is only proposed for deletion when
//      it is BOTH a near-duplicate of the best shot AND clearly lower quality.
//    • The best shot is never in its own deletion set (enforced twice).
//
//  If any of these fail, the app can recommend deleting a photo the user wants
//  to keep — the one outcome we must never allow.
//

import Testing
import Foundation
@testable import TidyGallery

@Suite("Safety invariants")
struct SafetyInvariantTests {

    private let scorer = ShotScorer(config: .default)
    private let similarPrint = FeaturePrint(vector: [1, 0, 0])
    private let differentPrint = FeaturePrint(vector: [0, 1, 0])

    // MARK: - Favorite hard lock

    @Test("A favorite is never pre-selected, even when it's the worst shot")
    func favoriteHardLock() {
        let best = PhotoAsset.make(
            id: "sharp", secondsFromEpoch: 100,
            featurePrint: similarPrint, score: .plain(sharpness: 0.9)
        )
        // Worse, visually identical, BUT favorited → must be protected.
        let favorite = PhotoAsset.make(
            id: "fav", secondsFromEpoch: 102, favorite: true,
            featurePrint: similarPrint, score: .plain(sharpness: 0.2, favorite: true)
        )

        let stack = scorer.makeStack(from: ["sharp", "fav"], assetsByID: indexed([best, favorite]))
        let unwrapped = try! #require(stack)

        #expect(unwrapped.bestShotID == "sharp")
        #expect(!unwrapped.assetsPreselectedForDeletion.contains("fav"))
        #expect(unwrapped.assetsPreselectedForDeletion.isEmpty)
    }

    @Test("A favorite still wins best shot on a tie (tiebreak boost)")
    func favoriteWinsTies() {
        let plain = PhotoAsset.make(
            id: "plain", secondsFromEpoch: 100,
            featurePrint: similarPrint, score: .plain(sharpness: 0.5)
        )
        let favorite = PhotoAsset.make(
            id: "fav", secondsFromEpoch: 102, favorite: true,
            featurePrint: similarPrint, score: .plain(sharpness: 0.5, favorite: true)
        )
        let stack = try! #require(
            scorer.makeStack(from: ["plain", "fav"], assetsByID: indexed([plain, favorite]))
        )
        #expect(stack.bestShotID == "fav")
    }

    // MARK: - Conservative pre-selection

    @Test("Clearly-worse near-duplicate IS pre-selected")
    func preselectsInferiorDuplicate() {
        let best = PhotoAsset.make(
            id: "best", secondsFromEpoch: 100,
            featurePrint: similarPrint, score: .plain(sharpness: 0.9)
        )
        let inferior = PhotoAsset.make(
            id: "blur", secondsFromEpoch: 102,
            featurePrint: similarPrint, score: .plain(sharpness: 0.2)
        )
        let stack = try! #require(
            scorer.makeStack(from: ["best", "blur"], assetsByID: indexed([best, inferior]))
        )
        #expect(stack.assetsPreselectedForDeletion == ["blur"])
    }

    @Test("Worse but visually DIFFERENT photo is NOT pre-selected")
    func keepsDissimilarPhoto() {
        let best = PhotoAsset.make(
            id: "best", secondsFromEpoch: 100,
            featurePrint: similarPrint, score: .plain(sharpness: 0.9)
        )
        // Much worse quality, but not a near-duplicate → keep it.
        let different = PhotoAsset.make(
            id: "other", secondsFromEpoch: 102,
            featurePrint: differentPrint, score: .plain(sharpness: 0.2)
        )
        let stack = try! #require(
            scorer.makeStack(from: ["best", "other"], assetsByID: indexed([best, different]))
        )
        #expect(stack.assetsPreselectedForDeletion.isEmpty)
    }

    @Test("Near-duplicate that is only slightly worse is NOT pre-selected")
    func keepsComparablePhoto() {
        let best = PhotoAsset.make(
            id: "best", secondsFromEpoch: 100,
            featurePrint: similarPrint, score: .plain(sharpness: 0.90)
        )
        let almostAsGood = PhotoAsset.make(
            id: "twin", secondsFromEpoch: 102,
            featurePrint: similarPrint, score: .plain(sharpness: 0.85)
        )
        let stack = try! #require(
            scorer.makeStack(from: ["best", "twin"], assetsByID: indexed([best, almostAsGood]))
        )
        // Quality gap (~0.03 composite) is under the 0.15 margin → keep.
        #expect(stack.assetsPreselectedForDeletion.isEmpty)
    }

    // MARK: - Structural guarantees

    @Test("PhotoStack.init strips the best shot from any deletion set")
    func initStripsBestShot() {
        let a = PhotoAsset.make(id: "a", featurePrint: similarPrint, score: .plain(sharpness: 0.9))
        let b = PhotoAsset.make(id: "b", featurePrint: similarPrint, score: .plain(sharpness: 0.2))
        // Deliberately (wrongly) include the best shot in the deletion set.
        let stack = PhotoStack(
            assets: [a, b],
            bestShotID: "a",
            rankedAssetIDs: ["a", "b"],
            assetsPreselectedForDeletion: ["a", "b"]
        )
        #expect(!stack.assetsPreselectedForDeletion.contains("a"))
        #expect(stack.assetsPreselectedForDeletion == ["b"])
    }

    @Test("Single-photo clusters are not actionable stacks")
    func singletonsIgnored() {
        let a = PhotoAsset.make(id: "a", featurePrint: similarPrint, score: .plain(sharpness: 0.9))
        #expect(scorer.makeStack(from: ["a"], assetsByID: indexed([a])) == nil)
    }

    @Test("makeStacks drops non-actionable clusters")
    func makeStacksFilters() {
        let best = PhotoAsset.make(id: "best", secondsFromEpoch: 100,
                                   featurePrint: similarPrint, score: .plain(sharpness: 0.9))
        let inferior = PhotoAsset.make(id: "blur", secondsFromEpoch: 102,
                                       featurePrint: similarPrint, score: .plain(sharpness: 0.2))
        let lonely = PhotoAsset.make(id: "solo", secondsFromEpoch: 500,
                                     featurePrint: differentPrint, score: .plain(sharpness: 0.5))
        let stacks = scorer.makeStacks(
            from: [["best", "blur"], ["solo"]],
            assetsByID: indexed([best, inferior, lonely])
        )
        #expect(stacks.count == 1)
        #expect(stacks.first?.bestShotID == "best")
    }
}
