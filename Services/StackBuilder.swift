//
//  StackBuilder.swift
//  TidyGallery
//
//  Groups analysed photos into "stacks" of near-duplicates.
//
//  Algorithm (and why it scales to 20k+):
//  1. SORT by creationDate.
//  2. NEIGHBOUR SEARCH. For each photo, compare its feature print only against
//     the next `duplicateNeighborLookahead` photos in time order, stopping early
//     once the time gap exceeds `burstTimeWindow`. This bounds the work to
//     O(n*k) instead of O(n^2), yet - unlike a hard time bucket - it groups
//     duplicates spread across a shooting session (seconds to minutes apart),
//     not just rapid-fire bursts. Visual similarity is the real duplicate test;
//     time only limits how far the search looks. An optional location gate
//     rejects pairs far apart in space.
//  3. UNION-FIND to form connected components -> stacks (transitively chains a
//     run of similar shots even when only neighbours are directly compared).
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
    /// Only assets with a feature print participate; unanalysed or undated
    /// assets are returned as singletons so nothing is silently dropped.
    func cluster(_ assets: [PhotoAsset]) -> [[PhotoAsset.ID]] {
        guard !assets.isEmpty else { return [] }

        // Sort by creation date (undated sort to the end; they never anchor a
        // group and so remain singletons).
        let sorted = assets.sorted {
            ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture)
        }

        var uf = UnionFind(count: sorted.count)
        let lookahead = max(1, config.duplicateNeighborLookahead)

        for i in 0..<sorted.count {
            // An undated or unanalysed photo can't anchor a near-duplicate group.
            guard let dateA = sorted[i].creationDate,
                  let printA = sorted[i].featurePrint else { continue }
            let locationA = sorted[i].location

            var compared = 0
            var j = i + 1
            while j < sorted.count && compared < lookahead {
                guard let dateB = sorted[j].creationDate else { break } // undated -> end of run
                if dateB.timeIntervalSince(dateA) > config.burstTimeWindow { break }
                compared += 1
                defer { j += 1 }

                guard let printB = sorted[j].featurePrint else { continue }

                // Location gate (only when both have coordinates).
                if let locationA, let locationB = sorted[j].location,
                   locationA.distance(from: locationB) > config.maxBurstDistanceMeters {
                    continue
                }
                if printA.distance(to: printB) <= config.featurePrintSimilarityThreshold {
                    uf.union(i, j)
                }
            }
        }

        // Collect connected components, preserving time order within each.
        var groups: [Int: [PhotoAsset.ID]] = [:]
        for idx in 0..<sorted.count {
            groups[uf.find(idx), default: []].append(sorted[idx].id)
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
