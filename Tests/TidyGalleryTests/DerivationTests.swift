//
//  DerivationTests.swift
//  TidyGalleryTests
//
//  Covers the derivation logic extracted from the scan coordinator: which
//  photos are surfaced as blurry, how reclaimable space is totalled across
//  overlapping categories, and how stacks survive deletions.
//

import Testing
import Foundation
@testable import TidyGallery

// MARK: - Blurry singles

@Suite("Blurry singles selection")
struct BlurrySinglesSelectorTests {

    private func asset(
        id: String,
        sharpness: Double,
        favorite: Bool = false,
        aesthetics: Double? = nil,
        labels: [String] = []
    ) -> PhotoAsset {
        var a = PhotoAsset.make(
            id: id,
            secondsFromEpoch: 0,
            favorite: favorite,
            featurePrint: FeaturePrint(vector: [1, 0]),
            score: .plain(sharpness: sharpness, aesthetics: aesthetics, favorite: favorite)
        )
        a.classificationLabels = labels.map { ClassificationLabel(identifier: $0, confidence: 0.9) }
        return a
    }

    // MARK: Sharp-but-low-texture exclusions
    //
    // Real device output surfaced a Possibly-blurry list full of sunsets and
    // otherwise good photos. Variance-of-Laplacian measures detail, not focus,
    // so a smooth in-focus scene scores as low as a genuine blur. These lock the
    // two signals that tell them apart.

    @Test("A sharp sunset is not surfaced as blurry")
    func natureSceneIsNotBlurry() {
        // Low sharpness (smooth sky), but tagged nature and no faces.
        let sunset = asset(id: "sunset", sharpness: 0.001, labels: ["sunset"])
        let realBlur = asset(id: "blur", sharpness: 0.001, labels: ["indoor"])

        let selected = BlurrySinglesSelector(config: .default)
            .select(from: [sunset, realBlur])
            .map(\.id)

        #expect(!selected.contains("sunset"))
        #expect(selected.contains("blur"))
    }

    @Test("A good-looking photo is not surfaced as blurry")
    func highAestheticsIsNotBlurry() {
        // Same low sharpness; the aesthetics model likes one and not the other.
        let pretty = asset(id: "pretty", sharpness: 0.001, aesthetics: 0.8)
        let ugly = asset(id: "ugly", sharpness: 0.001, aesthetics: 0.2)

        let selected = BlurrySinglesSelector(config: .default)
            .select(from: [pretty, ugly])
            .map(\.id)

        #expect(!selected.contains("pretty"))
        #expect(selected.contains("ugly"))
    }

    @Test("A scenic shot with a person in it is judged on its own texture")
    func sceneWithPersonIsNotSparedByNatureRule() {
        // A face means the nature tag is vetoed, so this photo isn't excluded on
        // "it's scenery" grounds — but a real person adds texture, so a genuinely
        // blurry one should still be catchable. Here it has no rescuing signal.
        var withPerson = asset(id: "person", sharpness: 0.001, labels: ["beach"])
        withPerson.score = ShotScore(
            sharpness: 0.001, aesthetics: 0.2,
            faceQuality: FaceQuality(faceCount: 1, eyesOpenScore: 0.5, smileScore: 0.5),
            isFavorite: false
        )
        let selected = BlurrySinglesSelector(config: .default)
            .select(from: [withPerson])
            .map(\.id)
        #expect(selected.contains("person"))
    }

    @Test("A uniformly soft library is still bounded by the percentile")
    func softLibraryIsNotAllFlagged() {
        // Every photo is below the absolute ceiling. Without the relative floor
        // this would flag all 20 — the bug that made the category a dump.
        let assets = (0..<20).map { asset(id: "\($0)", sharpness: 0.01 + Double($0) * 0.002) }
        let selected = BlurrySinglesSelector(config: .default).select(from: assets)

        #expect(!selected.isEmpty)
        #expect(selected.count < assets.count)
    }

    @Test("A sharp library flags nothing")
    func sharpLibraryFlagsNothing() {
        let assets = (0..<20).map { asset(id: "\($0)", sharpness: 0.6 + Double($0) * 0.01) }
        #expect(BlurrySinglesSelector(config: .default).select(from: assets).isEmpty)
    }

    @Test("Favorites are never surfaced")
    func favoritesExcluded() {
        let assets = [
            asset(id: "fav", sharpness: 0.001, favorite: true),
            asset(id: "plain", sharpness: 0.001)
        ]
        let selected = BlurrySinglesSelector(config: .default).select(from: assets)
        #expect(!selected.contains { $0.isFavorite })
    }

    @Test("Excluded ids (already grouped, or ignored) are skipped")
    func excludedSkipped() {
        let assets = [asset(id: "a", sharpness: 0.001), asset(id: "b", sharpness: 0.001)]
        let selected = BlurrySinglesSelector(config: .default)
            .select(from: assets, excluding: ["a"])
        #expect(!selected.contains { $0.id == "a" })
    }

    @Test("Never exceeds the hard cap")
    func respectsCap() {
        var config = AnalysisConfiguration.default
        config.blurryMaxCount = 3
        config.blurryPercentile = 1.0          // everything is "relatively" soft
        let assets = (0..<50).map { asset(id: "\($0)", sharpness: 0.001) }

        #expect(BlurrySinglesSelector(config: config).select(from: assets).count == 3)
    }

    @Test("Softest photos come first")
    func sortedBySoftness() {
        var config = AnalysisConfiguration.default
        config.blurryPercentile = 1.0
        let assets = [
            asset(id: "mid", sharpness: 0.05),
            asset(id: "worst", sharpness: 0.01),
            asset(id: "best", sharpness: 0.10)
        ]
        let selected = BlurrySinglesSelector(config: config).select(from: assets)
        #expect(selected.first?.id == "worst")
    }

    @Test("An empty library yields nothing (no crash on percentile maths)")
    func emptyInput() {
        #expect(BlurrySinglesSelector(config: .default).select(from: []).isEmpty)
    }

    @Test("A single photo doesn't trip the percentile index")
    func singlePhoto() {
        let selected = BlurrySinglesSelector(config: .default)
            .select(from: [asset(id: "only", sharpness: 0.001)])
        #expect(selected.count <= 1)
    }
}

// MARK: - Storage summary

@Suite("Storage summary maths")
struct StorageSummaryBuilderTests {

    @Test("Overlapping categories are counted once in the total")
    func unionIsDeduplicated() {
        // "shared" is both a screenshot and a big file. Summing the line items
        // would double-count it and overstate what deleting actually frees.
        let input = StorageSummaryBuilder.Input(
            bigFileIDs: ["shared", "big"],
            screenshotIDs: ["shared", "shot"]
        )
        let sizes = ["shared": Int64(100), "big": 10, "shot": 1]
        let summary = StorageSummaryBuilder.build(input, sizes: sizes)

        #expect(summary.reclaimableBytes == 111)          // 100 + 10 + 1, not 211
        #expect(summary.bigFiles.bytes == 110)            // line items report their own ids
        #expect(summary.screenshots.bytes == 101)
    }

    @Test("Line items report their own counts")
    func lineItemCounts() {
        let input = StorageSummaryBuilder.Input(
            exactDuplicateIDs: ["a", "b"],
            videoIDs: ["v"]
        )
        let summary = StorageSummaryBuilder.build(input, sizes: ["a": 1, "b": 2, "v": 3])

        #expect(summary.exactDuplicates.count == 2)
        #expect(summary.exactDuplicates.bytes == 3)
        #expect(summary.largeVideos.count == 1)
        #expect(summary.reclaimableBytes == 6)
    }

    @Test("Unmeasured assets contribute no bytes but still count")
    func missingSizes() {
        let input = StorageSummaryBuilder.Input(screenshotIDs: ["known", "unknown"])
        let summary = StorageSummaryBuilder.build(input, sizes: ["known": 50])

        #expect(summary.screenshots.count == 2)
        #expect(summary.screenshots.bytes == 50)
    }

    @Test("No ids yields the empty summary")
    func emptyInput() {
        let summary = StorageSummaryBuilder.build(.init(), sizes: [:])
        #expect(summary == .empty)
        #expect(!summary.hasReclaimableSpace)
    }
}

// MARK: - Stack pruning

@Suite("Stack pruning after deletion")
struct StackPruningTests {

    private func stack(preselected: Set<String> = ["b"]) -> PhotoStack {
        let a = PhotoAsset.make(id: "a", secondsFromEpoch: 1)
        let b = PhotoAsset.make(id: "b", secondsFromEpoch: 2)
        let c = PhotoAsset.make(id: "c", secondsFromEpoch: 3)
        return PhotoStack(
            assets: [a, b, c],
            bestShotID: "a",
            rankedAssetIDs: ["a", "b", "c"],
            assetsPreselectedForDeletion: preselected
        )
    }

    @Test("Removing one member keeps the stack and drops it from pre-selection")
    func removesMember() {
        let original = stack()
        let pruned = try! #require(original.removing(["b"]))
        #expect(pruned.assets.map(\.id) == ["a", "c"])
        #expect(!pruned.assetsPreselectedForDeletion.contains("b"))
        #expect(pruned.id == original.id)          // stack identity is preserved
    }

    @Test("Falling below two photos dissolves the stack")
    func dissolvesWhenTooSmall() {
        #expect(stack().removing(["b", "c"]) == nil)
    }

    @Test("Deleting the best shot promotes the top surviving photo")
    func promotesNewBestShot() {
        let pruned = try! #require(stack().removing(["a"]))
        #expect(pruned.bestShotID == "b")
        #expect(pruned.assets.contains { $0.id == pruned.bestShotID })
    }

    @Test("Removing nothing returns the stack unchanged")
    func noopRemoval() {
        let original = stack()
        let pruned = try! #require(original.removing([]))
        #expect(pruned.assets.count == original.assets.count)
    }

    @Test("The best shot always exists among the survivors")
    func bestShotAlwaysValid() {
        for removed in [["a"], ["b"], ["c"], ["a", "b"]] {
            if let pruned = stack().removing(Set(removed)) {
                #expect(pruned.assets.contains { $0.id == pruned.bestShotID })
            }
        }
    }
}
