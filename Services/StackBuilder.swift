//
//  StackBuilder.swift
//  TidyGallery
//
//  Groups analysed photos into "stacks" of near-duplicates.
//
//  Algorithm (and why it scales to 20k+):
//  1. TIME GATE FIRST. Sort by creationDate and split into buckets wherever the
//     gap between consecutive photos exceeds `burstTimeWindow` (~10s). This is
//     O(n log n) and immediately collapses the problem from "compare everything
//     to everything" (O(n²) ≈ 400M ops for 20k) to many tiny buckets.
//  2. VISUAL REFINE within each bucket only. Compare feature prints pairwise
//     *inside* a bucket (buckets are small, so this is cheap) and union photos
//     whose distance is below threshold. Optional location gate rejects pairs
//     that are far apart in space.
//  3. UNION-FIND to form connected components → stacks.
//
//  Pure and `Sendable`-friendly: takes value types in, returns clusters of ids.
//

import Foundation
import CoreLocation

struct StackBuilder {

    let config: AnalysisConfiguration

    init(config: AnalysisConfiguration = .default) {
        self.config = config
    }

    /// Groups analysed assets into clusters of `PhotoAsset.ID`.
    /// Only assets with a feature print participate; unanalysed assets are
    /// returned as singletons so nothing is silently dropped.
    func cluster(_ assets: [PhotoAsset]) -> [[PhotoAsset.ID]] {
        guard !assets.isEmpty else { return [] }

        // Sort by creation date (nil dates sort to the end, each isolated).
        let sorted = assets.sorted {
            ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture)
        }

        var clusters: [[PhotoAsset.ID]] = []
        var bucket: [PhotoAsset] = []
        var lastDate: Date?

        func flush() {
            if !bucket.isEmpty {
                clusters.append(contentsOf: refine(bucket))
                bucket.removeAll(keepingCapacity: true)
            }
        }

        for asset in sorted {
            defer { lastDate = asset.creationDate }
            guard let date = asset.creationDate else {
                // No timestamp → can't be part of a time burst; flush & isolate.
                flush()
                clusters.append([asset.id])
                lastDate = nil
                continue
            }
            if let last = lastDate, date.timeIntervalSince(last) > config.burstTimeWindow {
                flush()
            }
            bucket.append(asset)
        }
        flush()
        return clusters
    }

    // MARK: - Visual refinement within a time bucket

    /// Splits one time bucket into visually-coherent sub-clusters using
    /// union-find over pairwise feature-print distance.
    private func refine(_ bucket: [PhotoAsset]) -> [[PhotoAsset.ID]] {
        if bucket.count == 1 { return [[bucket[0].id]] }

        var uf = UnionFind(count: bucket.count)

        for i in 0..<bucket.count {
            let a = bucket[i]
            guard let pa = a.featurePrint else { continue }
            for j in (i + 1)..<bucket.count {
                let b = bucket[j]
                guard let pb = b.featurePrint else { continue }

                // Location gate (only when both have coordinates).
                if let la = a.location, let lb = b.location,
                   la.distance(from: lb) > config.maxBurstDistanceMeters {
                    continue
                }

                if pa.distance(to: pb) <= config.featurePrintSimilarityThreshold {
                    uf.union(i, j)
                }
            }
        }

        // Collect components.
        var groups: [Int: [PhotoAsset.ID]] = [:]
        for idx in 0..<bucket.count {
            groups[uf.find(idx), default: []].append(bucket[idx].id)
        }
        return Array(groups.values)
    }
}

// MARK: - Union-Find (disjoint set) with path compression + union by rank

private struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        // Path compression.
        var cur = x
        while parent[cur] != root {
            let next = parent[cur]
            parent[cur] = root
            cur = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if rank[ra] < rank[rb] {
            parent[ra] = rb
        } else if rank[ra] > rank[rb] {
            parent[rb] = ra
        } else {
            parent[rb] = ra
            rank[ra] += 1
        }
    }
}
