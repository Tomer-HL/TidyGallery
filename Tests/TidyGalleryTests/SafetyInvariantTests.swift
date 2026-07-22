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
//    • An action only ever touches photos the user can currently SEE.
//
//  If any of these fail, the app can recommend deleting a photo the user wants
//  to keep — the one outcome we must never allow.
//
//  A note on the last one. Everything above it concerns which photos get
//  *proposed*; it was added after an audit noticed that nothing in this file
//  concerned what happens between the user confirming and `deleteAssets` being
//  called. That gap contained a real bug — see `ActionableSelection`.
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

    // MARK: - Face signals combine without any one of them dominating
    //
    // Best-shot selection now weighs eyes, Apple's capture quality, smile and
    // framing. The risk of adding signals is that a preference starts
    // outvoting a defect — that a well-framed photo of someone blinking beats
    // a plainly-composed one where their eyes are open.

    @Test("A blink still loses to open eyes, however good the rest is")
    func blinkStillLoses() {
        let blinking = FaceQuality(
            faceCount: 1, eyesOpenScore: 0.05, smileScore: 1.0,
            captureQuality: 0.9, framingScore: 1.0
        )
        let awake = FaceQuality(
            faceCount: 1, eyesOpenScore: 0.95, smileScore: 0.2,
            captureQuality: 0.5, framingScore: 0.5
        )
        // Not merely lower — lower by a margin worth trusting. This ordering
        // held at a 0.03 gap under an earlier weighting, which is close enough
        // to a tie that any later tweak could have flipped it silently.
        let gap = (awake.combinedScore ?? 0) - (blinking.combinedScore ?? 1)
        #expect(gap > 0.08, "a blink must lose decisively, not narrowly")
    }

    @Test("A blink loses on realistic inputs too, not just adversarial ones")
    func blinkLosesInPractice() {
        // Apple's capture quality already penalises a blink, so the two signals
        // correlate in real photos. That correlation is welcome but must not be
        // what the invariant rests on — hence the adversarial case above.
        let blinking = FaceQuality(
            faceCount: 1, eyesOpenScore: 0.1, smileScore: 0.7,
            captureQuality: 0.35, framingScore: 0.9
        )
        let awake = FaceQuality(
            faceCount: 1, eyesOpenScore: 0.9, smileScore: 0.7,
            captureQuality: 0.75, framingScore: 0.9
        )
        #expect((blinking.combinedScore ?? 1) < (awake.combinedScore ?? 0))
    }

    @Test("Framing alone cannot outvote everything else")
    func framingIsARefinementNotAVeto() {
        // Same photo, one slightly clipped. It should lose — but only just,
        // because being cut off matters less than being sharp and awake.
        let wellFramed = FaceQuality(
            faceCount: 1, eyesOpenScore: 0.8, smileScore: 0.6,
            captureQuality: 0.7, framingScore: 1.0
        )
        let clipped = FaceQuality(
            faceCount: 1, eyesOpenScore: 0.8, smileScore: 0.6,
            captureQuality: 0.7, framingScore: 0.2
        )
        let gap = (wellFramed.combinedScore ?? 0) - (clipped.combinedScore ?? 0)
        #expect(gap > 0)
        #expect(gap < 0.15, "framing should nudge the ranking, not decide it")
    }

    @Test("Unmeasured signals redistribute rather than counting as average")
    func missingSignalsDoNotDragTowardTheMiddle() {
        // A face whose lips Vision couldn't resolve should be judged on what
        // WAS measured. Substituting 0.5 would penalise a great photo for a
        // detection failure that says nothing about it.
        let measuredOnly = FaceQuality(
            faceCount: 1, eyesOpenScore: 0.9, smileScore: nil,
            captureQuality: 0.9, framingScore: nil
        )
        #expect(abs((measuredOnly.combinedScore ?? 0) - 0.9) < 0.0001)
    }

    @Test("Faces found but nothing measurable is neutral, not zero")
    func unmeasurableFaceIsNeutral() {
        // Scoring 0 would make "Vision saw a face but resolved nothing" look
        // identical to "everyone is blinking", and pre-select a photo that may
        // be perfectly good.
        let opaque = FaceQuality(
            faceCount: 2, eyesOpenScore: nil, smileScore: nil,
            captureQuality: nil, framingScore: nil
        )
        #expect(opaque.combinedScore == 0.5)
    }

    @Test("A photo with no faces still declines to have an opinion")
    func noFacesStaysNil() {
        // The composite redistributes the face weight when this is nil, so a
        // landscape isn't penalised for lacking people.
        #expect(FaceQuality.noFaces.combinedScore == nil)
        #expect(!FaceQuality.noFaces.hasFaces)
    }

    // MARK: - Never act on what the user cannot see
    //
    // The cleanup grid holds `selected` as a flat set of ids beside a
    // separately-derived `displayed` list. These pin the rule that keeps the
    // two from drifting into a deletion the user never saw.

    @Test("A selection hidden by a filter is not deleted")
    func filteredOutSelectionIsNotActedOn() {
        // The original bug, in its simplest form: select four, filter down to
        // two, tap Delete. `Array(selected)` would have deleted all four.
        let selected: Set<String> = ["a", "b", "c", "d"]
        let displayed = ["a", "b"]

        let actionable = ActionableSelection.resolve(selected: selected, displayed: displayed)

        #expect(actionable == ["a", "b"])
        #expect(!actionable.contains("c"))
        #expect(!actionable.contains("d"))
    }

    @Test("The count the user confirms equals the count deleted")
    func confirmedCountMatchesDeletedCount() {
        // The confirmation sheet said "Delete 4?" while the grid showed 2.
        // Whatever the number is, it must be the same number in both places.
        let selected: Set<String> = ["a", "b", "c", "d"]
        let displayed = ["a", "b"]

        let actionable = ActionableSelection.resolve(selected: selected, displayed: displayed)

        #expect(actionable.count == 2)
        #expect(actionable.count != selected.count)   // the whole point
    }

    @Test("A late-arriving size floor cannot delete what it hid")
    func lateSizeFloorCannotDeleteHiddenPhotos() {
        // Needs no user mistake at all: the big-file size floor is only applied
        // once `sizes` loads, so a photo tapped during that window disappears
        // from the grid a moment later while staying selected.
        let selected: Set<String> = ["big", "small"]
        let displayedAfterFloorApplied = ["big"]

        let actionable = ActionableSelection.resolve(
            selected: selected,
            displayed: displayedAfterFloorApplied
        )

        #expect(actionable == ["big"])
    }

    @Test("Selection survives a filter round trip")
    func selectionSurvivesFilterRoundTrip() {
        // Intersecting at the point of use rather than pruning the stored set:
        // hiding a photo and showing it again must bring its checkmark back,
        // or users lose work every time they touch the filter.
        let selected: Set<String> = ["a", "b"]

        let whileFiltered = ActionableSelection.resolve(selected: selected, displayed: ["a"])
        let afterRestoring = ActionableSelection.resolve(selected: selected, displayed: ["a", "b"])

        #expect(whileFiltered == ["a"])
        #expect(afterRestoring == ["a", "b"])
    }

    @Test("Nothing displayed means nothing is actionable")
    func emptyDisplayMeansNoAction() {
        let actionable = ActionableSelection.resolve(
            selected: ["a", "b", "c"],
            displayed: [String]()
        )
        #expect(actionable.isEmpty)
    }

    @Test("Select All reflects the visible list, not the stored set")
    func allVisibleSelectedIgnoresHiddenItems() {
        // Was `selected.count == displayed.count`: two selected, two displayed,
        // but only ONE of the displayed ones is actually selected — so the
        // button read "Deselect All" over a half-selected grid.
        #expect(
            !ActionableSelection.allVisibleSelected(
                selected: ["a", "hidden"],
                displayed: ["a", "b"]
            )
        )
        #expect(
            ActionableSelection.allVisibleSelected(
                selected: ["a", "b", "hidden"],
                displayed: ["a", "b"]
            )
        )
    }

    @Test("An empty grid is never 'all selected'")
    func emptyGridIsNotAllSelected() {
        // Answering true would offer a Deselect All that does nothing.
        #expect(
            !ActionableSelection.allVisibleSelected(selected: [], displayed: [String]())
        )
        #expect(
            !ActionableSelection.allVisibleSelected(selected: ["ghost"], displayed: [String]())
        )
    }

    // MARK: - The best shot is never in the deletion set (ReviewModel)
    //
    // `PhotoStack.init` has always enforced this, but `ReviewModel.Stack` is the
    // type the UI actually binds to and it did not. The gap was reachable:
    // `removeDeleted` re-elects `ranked.first` when the best shot is deleted,
    // and in a burst that is very often one of the pre-checked extras — leaving
    // a photo starred as "best" and still queued for deletion, with the tile
    // hiding the toggle that would have let the user untick it.

    @MainActor
    @Test("A Stack strips the best shot from its checked set on construction")
    func reviewStackStripsBestShotOnInit() {
        let stack = ReviewModel.Stack(
            id: UUID(),
            assets: [PhotoAsset.make(id: "best"), PhotoAsset.make(id: "extra")],
            rankedIDs: ["best", "extra"],
            bestShotID: "best",
            checkedForDeletion: ["best", "extra"]   // best wrongly included
        )

        #expect(!stack.checkedForDeletion.contains("best"))
        #expect(stack.checkedForDeletion == ["extra"])
    }

    @MainActor
    @Test("Deleting the best shot never promotes a photo that stays checked")
    func promotedBestShotIsNeverStillChecked() {
        // The concrete scenario: a three-shot burst where the two extras are
        // pre-checked. The user unchecks nothing but deletes the best shot from
        // somewhere else, so `removeDeleted` promotes the next-ranked photo —
        // which is checked.
        let model = ReviewModel(stacks: [
            PhotoStack(
                assets: [
                    PhotoAsset.make(id: "a", featurePrint: similarPrint, score: .plain(sharpness: 0.9)),
                    PhotoAsset.make(id: "b", featurePrint: similarPrint, score: .plain(sharpness: 0.5)),
                    PhotoAsset.make(id: "c", featurePrint: similarPrint, score: .plain(sharpness: 0.3))
                ],
                bestShotID: "a",
                rankedAssetIDs: ["a", "b", "c"],
                assetsPreselectedForDeletion: ["b", "c"]
            )
        ])

        model.removeDeleted(["a"])

        guard let stack = model.stacks.first else {
            Issue.record("the stack should survive with two photos left")
            return
        }
        #expect(stack.bestShotID == "b")                       // promoted
        #expect(!stack.checkedForDeletion.contains("b"))        // and unchecked
        #expect(!model.assetsToDelete.contains(stack.bestShotID))
    }

    @MainActor
    @Test("assetsToDelete never contains any stack's best shot")
    func assetsToDeleteExcludesEveryBestShot() {
        let model = ReviewModel(stacks: [
            PhotoStack(
                assets: [PhotoAsset.make(id: "a1"), PhotoAsset.make(id: "a2")],
                bestShotID: "a1",
                rankedAssetIDs: ["a1", "a2"],
                assetsPreselectedForDeletion: ["a2"]
            ),
            PhotoStack(
                assets: [PhotoAsset.make(id: "b1"), PhotoAsset.make(id: "b2")],
                bestShotID: "b1",
                rankedAssetIDs: ["b1", "b2"],
                assetsPreselectedForDeletion: ["b2"]
            )
        ])

        let toDelete = Set(model.assetsToDelete)
        for stack in model.stacks {
            #expect(!toDelete.contains(stack.bestShotID))
        }
        #expect(toDelete == ["a2", "b2"])
    }

    @MainActor
    @Test("Promoting a checked photo to best shot unchecks it")
    func promotingUnchecks() {
        let stackID = UUID()
        let model = ReviewModel(stacks: [
            PhotoStack(
                id: stackID,
                assets: [PhotoAsset.make(id: "a"), PhotoAsset.make(id: "b")],
                bestShotID: "a",
                rankedAssetIDs: ["a", "b"],
                assetsPreselectedForDeletion: ["b"]
            )
        ])

        model.setBestShot("b", inStack: stackID)

        #expect(model.stacks[0].bestShotID == "b")
        #expect(!model.assetsToDelete.contains("b"))
        #expect(model.assetsToDelete.isEmpty)
    }

    @MainActor
    @Test("'Check all extras' never checks the best shot")
    func checkAllExtrasSparesBestShot() {
        let stackID = UUID()
        let model = ReviewModel(stacks: [
            PhotoStack(
                id: stackID,
                assets: [PhotoAsset.make(id: "a"), PhotoAsset.make(id: "b"), PhotoAsset.make(id: "c")],
                bestShotID: "a",
                rankedAssetIDs: ["a", "b", "c"],
                assetsPreselectedForDeletion: []
            )
        ])

        model.checkAllExtras(inStack: stackID)

        #expect(model.stacks[0].checkedForDeletion == ["b", "c"])
        #expect(!model.assetsToDelete.contains("a"))
    }
}
