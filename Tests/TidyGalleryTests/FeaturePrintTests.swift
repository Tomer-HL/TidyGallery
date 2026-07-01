//
//  FeaturePrintTests.swift
//  TidyGalleryTests
//
//  Verifies the embedding math the whole clustering step depends on:
//  distance semantics (smaller = more similar), unit normalisation, and cosine.
//

import Testing
import Foundation
@testable import TidyGallery

@Suite("FeaturePrint math")
struct FeaturePrintTests {

    @Test("Identical vectors have zero distance and full similarity")
    func identical() {
        let a = FeaturePrint(vector: [1, 0, 0])
        let b = FeaturePrint(vector: [1, 0, 0])
        #expect(isClose(a.distance(to: b), 0))
        #expect(isClose(a.cosineSimilarity(to: b), 1))
    }

    @Test("Distance is invariant to scale (vectors are unit-normalised)")
    func scaleInvariance() {
        // [2,0,0] normalises to the same unit vector as [1,0,0].
        let a = FeaturePrint(vector: [1, 0, 0])
        let scaled = FeaturePrint(vector: [2, 0, 0])
        #expect(isClose(a.distance(to: scaled), 0))
        #expect(isClose(a.cosineSimilarity(to: scaled), 1))
    }

    @Test("Orthogonal vectors are maximally dissimilar")
    func orthogonal() {
        let a = FeaturePrint(vector: [1, 0])
        let b = FeaturePrint(vector: [0, 1])
        // Unit vectors 90° apart: L2 distance = sqrt(2), cosine = 0.
        #expect(isClose(a.distance(to: b), Float(2).squareRoot(), tol: 1e-3))
        #expect(isClose(a.cosineSimilarity(to: b), 0, tol: 1e-3))
    }

    @Test("Nearer vectors produce smaller distance than farther ones")
    func monotonic() {
        let ref = FeaturePrint(vector: [1, 0])
        let near = FeaturePrint(vector: [0.95, 0.05])
        let far = FeaturePrint(vector: [0.2, 0.8])
        #expect(ref.distance(to: near) < ref.distance(to: far))
    }

    @Test("Mismatched or empty vectors degrade safely, not crash")
    func degenerate() {
        let a = FeaturePrint(vector: [1, 0, 0])
        let empty = FeaturePrint(vector: [])
        let shorter = FeaturePrint(vector: [1, 0])
        #expect(a.distance(to: empty) == .greatestFiniteMagnitude)
        #expect(a.distance(to: shorter) == .greatestFiniteMagnitude)
        #expect(isClose(a.cosineSimilarity(to: shorter), 0))
    }
}
