//
//  StackBuilderTests.swift
//  TidyGalleryTests
//
//  The clustering step is where correctness AND scalability live. These tests
//  pin the two behaviours the design promises: (1) a time gap larger than the
//  burst window splits assets into separate stacks even if they look identical,
//  and (2) within the window, only visually-similar photos merge.
//

import Testing
import Foundation
@testable import TidyGallery

@Suite("StackBuilder clustering")
struct StackBuilderTests {

    private let config = AnalysisConfiguration.default   // 10s window, 0.55 sim
    private var builder: StackBuilder { StackBuilder(config: config) }

    /// Helper: does any returned cluster contain exactly this id set?
    private func hasCluster(_ clusters: [[PhotoAsset.ID]], _ ids: Set<String>) -> Bool {
        clusters.contains { Set($0) == ids }
    }

    @Test("Identical photos within the burst window merge into one stack")
    func mergesWithinWindow() {
        let print = FeaturePrint(vector: [1, 0, 0])
        let a = PhotoAsset.make(id: "a", secondsFromEpoch: 100, featurePrint: print)
        let b = PhotoAsset.make(id: "b", secondsFromEpoch: 105, featurePrint: print)

        let clusters = builder.cluster([a, b])
        #expect(clusters.count == 1)
        #expect(hasCluster(clusters, ["a", "b"]))
    }

    @Test("Identical photos MORE than 10s apart do NOT merge (time gate)")
    func timeGateSplits() {
        let print = FeaturePrint(vector: [1, 0, 0])
        let a = PhotoAsset.make(id: "a", secondsFromEpoch: 100, featurePrint: print)
        let b = PhotoAsset.make(id: "b", secondsFromEpoch: 130, featurePrint: print) // +30s

        let clusters = builder.cluster([a, b])
        #expect(clusters.count == 2)
        #expect(hasCluster(clusters, ["a"]))
        #expect(hasCluster(clusters, ["b"]))
    }

    @Test("Visually different photos within the window stay separate")
    func visualRefineSplits() {
        let a = PhotoAsset.make(id: "a", secondsFromEpoch: 100, featurePrint: FeaturePrint(vector: [1, 0]))
        let b = PhotoAsset.make(id: "b", secondsFromEpoch: 102, featurePrint: FeaturePrint(vector: [0, 1]))

        let clusters = builder.cluster([a, b])
        #expect(clusters.count == 2)
    }

    @Test("A burst chains transitively within the window")
    func transitiveChaining() {
        // Three near-identical shots 3s apart should form a single stack.
        let p = FeaturePrint(vector: [1, 0, 0])
        let assets = [
            PhotoAsset.make(id: "a", secondsFromEpoch: 100, featurePrint: p),
            PhotoAsset.make(id: "b", secondsFromEpoch: 103, featurePrint: p),
            PhotoAsset.make(id: "c", secondsFromEpoch: 106, featurePrint: p)
        ]
        let clusters = builder.cluster(assets)
        #expect(clusters.count == 1)
        #expect(hasCluster(clusters, ["a", "b", "c"]))
    }

    @Test("Assets without a creation date are isolated, never dropped")
    func noDateIsolated() {
        let dated = PhotoAsset.make(id: "a", secondsFromEpoch: 100, featurePrint: FeaturePrint(vector: [1, 0]))
        var undated = PhotoAsset.make(id: "b", featurePrint: FeaturePrint(vector: [1, 0]))
        undated = PhotoAsset(
            id: undated.id, creationDate: nil, modificationDate: nil,
            pixelWidth: 10, pixelHeight: 10, isFavorite: false, coordinate: nil,
            featurePrint: undated.featurePrint, score: nil
        )
        let clusters = builder.cluster([dated, undated])
        let allIDs = Set(clusters.flatMap { $0 })
        #expect(allIDs == ["a", "b"])            // nothing lost
        #expect(clusters.contains { $0 == ["b"] }) // the undated one is a singleton
    }
}
