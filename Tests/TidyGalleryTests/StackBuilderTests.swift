//
//  StackBuilderTests.swift
//  TidyGalleryTests
//
//  The clustering step is where correctness AND scalability live. These tests
//  pin the behaviours the design promises: (1) visually-similar photos taken
//  across a shooting session (seconds to minutes apart) merge, (2) photos more
//  than the time window apart do NOT merge, and (3) within range, only
//  visually-similar photos merge.
//

import Testing
import Foundation
@testable import TidyGallery

@Suite("StackBuilder clustering")
struct StackBuilderTests {

    private let config = AnalysisConfiguration.default   // 30-min window, 0.45 sim
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

    @Test("Similar photos spread across a session (30s+ apart) DO merge")
    func sessionSpreadMerges() {
        // The old 10s gate missed these real-world duplicates; the session-aware
        // search should now group them.
        let print = FeaturePrint(vector: [1, 0, 0])
        let a = PhotoAsset.make(id: "a", secondsFromEpoch: 100, featurePrint: print)
        let b = PhotoAsset.make(id: "b", secondsFromEpoch: 160, featurePrint: print) // +60s

        let clusters = builder.cluster([a, b])
        #expect(clusters.count == 1)
        #expect(hasCluster(clusters, ["a", "b"]))
    }

    @Test("Identical photos MORE than the time window apart do NOT merge")
    func farApartInTimeSplits() {
        let print = FeaturePrint(vector: [1, 0, 0])
        let a = PhotoAsset.make(id: "a", secondsFromEpoch: 100, featurePrint: print)
        // Beyond the 30-minute window (1800s).
        let b = PhotoAsset.make(id: "b", secondsFromEpoch: 100 + 2000, featurePrint: print)

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
