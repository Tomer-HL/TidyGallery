//
//  ExactDuplicateFinder.swift
//  TidyGallery
//
//  Finds *exact* duplicates: the same image present twice in the library, no
//  matter how far apart in time. This is the case visual clustering can't reach,
//  since `StackBuilder` only compares photos within a shooting session.
//
//  Why not hash the file bytes?
//  ---------------------------
//  Hashing every asset would mean reading gigabytes of original data. Instead we
//  exploit the fact that byte-identical copies MUST agree on cheap metadata:
//    1. BUCKET by (pixelWidth, pixelHeight, fileSize). Non-duplicates almost
//       never collide on all three, and this is O(n) over data we already have.
//    2. CONFIRM inside each bucket with the feature prints we already computed
//       and cached: identical images produce an identical embedding, so their
//       distance is ~0.
//  The result is effectively an exact match for a fraction of the cost, and it
//  reuses the existing analysis rather than doing new I/O.
//
//  Pure and `Sendable`-friendly, so it can run off the main actor.
//

import Foundation

struct ExactDuplicateFinder {

    let config: AnalysisConfiguration

    init(config: AnalysisConfiguration = .default) {
        self.config = config
    }

    /// Bucket key: exact copies must agree on all three.
    private struct Key: Hashable {
        let width: Int
        let height: Int
        let bytes: Int64
    }

    /// Groups of assets that are the same image. Every returned group has 2+
    /// members; assets without a known size or feature print are skipped.
    func groups(from assets: [PhotoAsset], sizes: [PhotoAsset.ID: Int64]) -> [[PhotoAsset]] {
        var buckets: [Key: [PhotoAsset]] = [:]
        for asset in assets {
            guard asset.featurePrint != nil,
                  let bytes = sizes[asset.id], bytes > 0 else { continue }
            let key = Key(width: asset.pixelWidth, height: asset.pixelHeight, bytes: bytes)
            buckets[key, default: []].append(asset)
        }

        var result: [[PhotoAsset]] = []
        for (_, members) in buckets where members.count > 1 {
            result.append(contentsOf: confirm(members))
        }
        return result
    }

    /// Splits a metadata bucket into groups whose feature prints are ~identical.
    private func confirm(_ members: [PhotoAsset]) -> [[PhotoAsset]] {
        var groups: [[PhotoAsset]] = []
        var unassigned = members

        while let seed = unassigned.first {
            unassigned.removeFirst()
            guard let seedPrint = seed.featurePrint else { continue }

            var group = [seed]
            unassigned.removeAll { candidate in
                guard let print = candidate.featurePrint,
                      seedPrint.distance(to: print) <= config.exactDuplicateDistanceEpsilon
                else { return false }
                group.append(candidate)
                return true
            }
            if group.count > 1 { groups.append(group) }
        }
        return groups
    }

    /// The copies that are safe to delete: everything except the one we keep.
    ///
    /// Safety rules, matching the rest of the app:
    ///  • Exactly one copy per group is always kept.
    ///  • FAVORITES ARE NEVER offered for deletion, and a favorite is preferred
    ///    as the copy we keep.
    ///  • Otherwise the oldest copy is kept (the original, not the re-save).
    func extras(in groups: [[PhotoAsset]]) -> [PhotoAsset] {
        groups.flatMap { group -> [PhotoAsset] in
            let ordered = group.sorted { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }   // favorites first
                let l = lhs.creationDate ?? .distantFuture
                let r = rhs.creationDate ?? .distantFuture
                return l < r                                                    // then oldest first
            }
            // Keep ordered[0]; never offer a favorite for deletion.
            return ordered.dropFirst().filter { !$0.isFavorite }
        }
    }
}
