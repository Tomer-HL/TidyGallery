//
//  ShotScorer.swift
//  TidyGallery
//
//  Turns a raw cluster of analysed assets into a `PhotoStack`: elects the best
//  shot, ranks the members, and produces a CONSERVATIVE pre-selection for
//  deletion.
//
//  Two safety rules are enforced here and are non-negotiable:
//    1. FAVORITES ARE HARD-LOCKED. A favorited asset is never pre-selected for
//       deletion, regardless of its quality. It may still win best shot.
//    2. CONSERVATIVE PRE-SELECTION. A member is only proposed for deletion when
//       it is BOTH very similar to the best shot AND clearly lower quality
//       (both gates in `AnalysisConfiguration`). When in doubt, keep it.
//
//  Nothing here deletes anything — it only produces a recommendation the user
//  must confirm.
//

import Foundation

struct ShotScorer {

    let config: AnalysisConfiguration

    init(config: AnalysisConfiguration = .default) {
        self.config = config
    }

    /// Build a `PhotoStack` from a cluster of ids resolved against `assetsByID`.
    /// Returns `nil` for degenerate clusters (empty, or a single photo — which
    /// isn't a cleanup opportunity).
    func makeStack(
        from ids: [PhotoAsset.ID],
        assetsByID: [PhotoAsset.ID: PhotoAsset]
    ) -> PhotoStack? {
        let members = ids.compactMap { assetsByID[$0] }
        guard members.count > 1 else { return nil }

        // Composite score per member (favorites get a modest tiebreak boost so a
        // favorite tends to win best shot, but scoring stays explainable).
        func compositeScore(_ asset: PhotoAsset) -> Double {
            guard let score = asset.score else { return 0 }
            var value = score.composite(using: config)
            if asset.isFavorite { value = min(1.0, value + 0.05) }
            return value
        }

        // Rank best → worst.
        let ranked = members.sorted { compositeScore($0) > compositeScore($1) }
        guard let best = ranked.first else { return nil }
        let bestScore = compositeScore(best)
        guard let bestPrint = best.featurePrint else {
            // No print on the winner → we can't reason about similarity; propose
            // nothing for deletion (safe default).
            return PhotoStack(
                assets: members,
                bestShotID: best.id,
                rankedAssetIDs: ranked.map(\.id),
                assetsPreselectedForDeletion: []
            )
        }

        // CONSERVATIVE pre-selection.
        var preselect: Set<PhotoAsset.ID> = []
        for asset in ranked.dropFirst() {
            // Rule 1: never a favorite.
            if asset.isFavorite { continue }

            // Must be clearly lower quality than the winner.
            let scoreGap = bestScore - compositeScore(asset)
            guard scoreGap >= config.preselectQualityMargin else { continue }

            // Must be a genuine near-duplicate of the winner.
            guard let print = asset.featurePrint else { continue }
            let distance = bestPrint.distance(to: print)
            guard distance <= config.preselectSimilarityThreshold else { continue }

            preselect.insert(asset.id)
        }

        return PhotoStack(
            assets: members,
            bestShotID: best.id,
            rankedAssetIDs: ranked.map(\.id),
            assetsPreselectedForDeletion: preselect
        )
    }

    /// Convenience: build all actionable stacks from clusters.
    func makeStacks(
        from clusters: [[PhotoAsset.ID]],
        assetsByID: [PhotoAsset.ID: PhotoAsset]
    ) -> [PhotoStack] {
        clusters.compactMap { makeStack(from: $0, assetsByID: assetsByID) }
                .filter(\.isActionable)
    }
}
