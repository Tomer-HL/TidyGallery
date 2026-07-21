//
//  ExactDuplicateFinderTests.swift
//  TidyGalleryTests
//
//  Exact-duplicate detection must be both correct and SAFE: one copy of every
//  group is always kept, and a favorite is never offered for deletion.
//

import Testing
import Foundation
@testable import TidyGallery

@Suite("Exact duplicate detection")
struct ExactDuplicateFinderTests {

    private let finder = ExactDuplicateFinder(config: .default)
    private let printA = FeaturePrint(vector: [1, 0, 0])
    private let printB = FeaturePrint(vector: [0, 1, 0])

    /// An asset with explicit dimensions so we can control the bucket key.
    private func asset(
        id: String,
        seconds: TimeInterval,
        favorite: Bool = false,
        width: Int = 4000,
        height: Int = 3000,
        print: FeaturePrint
    ) -> PhotoAsset {
        let date = Date(timeIntervalSince1970: seconds)
        return PhotoAsset(
            id: id, creationDate: date, modificationDate: date,
            pixelWidth: width, pixelHeight: height,
            isFavorite: favorite, coordinate: nil,
            featurePrint: print, score: nil
        )
    }

    @Test("Identical size, dimensions and print group together — even years apart")
    func groupsIdenticalCopies() {
        let original = asset(id: "a", seconds: 0, print: printA)
        let copy = asset(id: "b", seconds: 60_000_000, print: printA)   // much later
        let groups = finder.groups(from: [original, copy], sizes: ["a": 1_000, "b": 1_000])

        #expect(groups.count == 1)
        #expect(Set(groups[0].map(\.id)) == ["a", "b"])
    }

    @Test("Different byte size never groups, however similar")
    func differentSizeStaysApart() {
        let a = asset(id: "a", seconds: 0, print: printA)
        let b = asset(id: "b", seconds: 10, print: printA)
        #expect(finder.groups(from: [a, b], sizes: ["a": 1_000, "b": 1_001]).isEmpty)
    }

    @Test("Different dimensions never group")
    func differentDimensionsStayApart() {
        let a = asset(id: "a", seconds: 0, print: printA)
        let b = asset(id: "b", seconds: 10, width: 2000, height: 1500, print: printA)
        #expect(finder.groups(from: [a, b], sizes: ["a": 1_000, "b": 1_000]).isEmpty)
    }

    @Test("Same metadata but visually different does NOT group")
    func sameMetadataDifferentImage() {
        let a = asset(id: "a", seconds: 0, print: printA)
        let b = asset(id: "b", seconds: 10, print: printB)
        #expect(finder.groups(from: [a, b], sizes: ["a": 1_000, "b": 1_000]).isEmpty)
    }

    @Test("Extras keep exactly one copy — the oldest")
    func extrasKeepOldest() {
        let older = asset(id: "older", seconds: 100, print: printA)
        let newer = asset(id: "newer", seconds: 500, print: printA)
        let groups = finder.groups(from: [newer, older], sizes: ["older": 9, "newer": 9])
        let extras = finder.extras(in: groups)

        #expect(extras.map(\.id) == ["newer"])   // the oldest copy is kept
    }

    @Test("A favorite is never offered for deletion and is the copy kept")
    func favoriteIsProtected() {
        let plain = asset(id: "plain", seconds: 100, print: printA)
        let favorite = asset(id: "fav", seconds: 500, favorite: true, print: printA)
        let groups = finder.groups(from: [plain, favorite], sizes: ["plain": 9, "fav": 9])
        let extras = finder.extras(in: groups)

        #expect(!extras.contains { $0.isFavorite })
        #expect(extras.map(\.id) == ["plain"])   // favorite kept, plain copy offered
    }

    @Test("Every group always keeps at least one copy")
    func neverDeletesWholeGroup() {
        let a = asset(id: "a", seconds: 1, print: printA)
        let b = asset(id: "b", seconds: 2, print: printA)
        let c = asset(id: "c", seconds: 3, print: printA)
        let groups = finder.groups(from: [a, b, c], sizes: ["a": 5, "b": 5, "c": 5])
        let extras = finder.extras(in: groups)

        #expect(groups[0].count == 3)
        #expect(extras.count == 2)               // one survivor
    }
}
