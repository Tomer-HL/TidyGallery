//
//  FeaturePrint.swift
//  TidyGallery
//
//  A `Sendable` wrapper around a Vision feature-print vector.
//
//  Why wrap it? `FeaturePrintObservation` (the object Vision returns) is a
//  reference type and is NOT `Sendable`, so it cannot cross actor boundaries
//  under Swift 6 strict concurrency. We extract its raw bytes into a value
//  type at the moment of generation and pass THIS around instead. Distance is
//  recomputed from the stored floats, so we never need the original object.
//

import Foundation
import Accelerate

/// An immutable, `Sendable` image embedding produced by
/// `GenerateImageFeaturePrintRequest`.
struct FeaturePrint: Sendable, Hashable, Codable {

    /// The raw feature vector. Vision emits Float32 elements; we normalise to
    /// unit length once at creation so distance/similarity math is cheap later.
    let vector: [Float]

    init(vector: [Float]) {
        self.vector = FeaturePrint.normalised(vector)
    }

    /// Euclidean (L2) distance to another print. **Smaller = more similar.**
    /// Mirrors the semantics of `FeaturePrintObservation.distance(to:)` so the
    /// same thresholds in `AnalysisConfiguration` apply.
    func distance(to other: FeaturePrint) -> Float {
        guard vector.count == other.vector.count, !vector.isEmpty else {
            return .greatestFiniteMagnitude
        }
        var diff = [Float](repeating: 0, count: vector.count)
        vDSP.subtract(vector, other.vector, result: &diff)
        return vDSP.rootMeanSquare(diff) * Float(vector.count).squareRoot()
    }

    /// Cosine similarity in `[-1, 1]`. Provided for callers who prefer it; the
    /// clustering path uses `distance(to:)` to match Vision's native metric.
    func cosineSimilarity(to other: FeaturePrint) -> Float {
        guard vector.count == other.vector.count, !vector.isEmpty else { return 0 }
        return vDSP.dot(vector, other.vector) // unit vectors -> dot == cosine
    }

    private static func normalised(_ v: [Float]) -> [Float] {
        let norm = vDSP.rootMeanSquare(v) * Float(v.count).squareRoot()
        guard norm > 0 else { return v }
        var out = v
        vDSP.divide(v, norm, result: &out)
        return out
    }
}
