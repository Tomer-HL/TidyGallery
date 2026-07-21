//
//  PhotoStack.swift
//  TidyGallery
//
//  A group of visually-similar photos taken close in time, with one asset
//  elected "best shot" and a conservative set pre-selected for deletion.
//  Drives the Phase 2 UI directly.
//

import Foundation

/// A cluster of near-duplicate photos plus the analyzer's recommendation.
///
/// Safety invariant: `assetsPreselectedForDeletion` NEVER includes the best
/// shot and NEVER includes a favorite. This is enforced when the stack is
/// constructed by `ShotScorer`; the UI can only ever *reduce* the selection.
struct PhotoStack: Identifiable, Sendable, Hashable {

    let id: UUID

    /// All members, richest-first is not guaranteed; use `bestShotID` to find
    /// the winner and `rankedAssetIDs` for display order.
    let assets: [PhotoAsset]

    /// `id` of the elected best shot. Guaranteed to be a member of `assets`.
    let bestShotID: PhotoAsset.ID

    /// Member ids ordered best → worst by composite score.
    let rankedAssetIDs: [PhotoAsset.ID]

    /// The analyzer's *default* deletion suggestion. Conservative: only clearly
    /// inferior near-duplicates, never the best shot, never a favorite. The
    /// user confirms or trims this in Phase 2 — nothing is ever deleted without
    /// explicit confirmation.
    let assetsPreselectedForDeletion: Set<PhotoAsset.ID>

    init(
        id: UUID = UUID(),
        assets: [PhotoAsset],
        bestShotID: PhotoAsset.ID,
        rankedAssetIDs: [PhotoAsset.ID],
        assetsPreselectedForDeletion: Set<PhotoAsset.ID>
    ) {
        self.id = id
        self.assets = assets
        self.bestShotID = bestShotID
        self.rankedAssetIDs = rankedAssetIDs
        // Belt-and-braces: strip the best shot from the deletion set even if a
        // caller passed it in, so the invariant can never be violated.
        self.assetsPreselectedForDeletion = assetsPreselectedForDeletion
            .subtracting([bestShotID])
    }

    var bestShot: PhotoAsset? { assets.first { $0.id == bestShotID } }

    /// A stack is only worth surfacing when it has more than one photo.
    var isActionable: Bool { assets.count > 1 && !assetsPreselectedForDeletion.isEmpty }

    /// Estimated reclaimable count if the user accepts the suggestion as-is.
    var reclaimableCount: Int { assetsPreselectedForDeletion.count }

    /// A copy of this stack with `removed` assets dropped, or `nil` when fewer
    /// than two photos survive (a lone photo is no longer a cleanup group).
    ///
    /// If the best shot itself was removed, the highest-ranked survivor
    /// inherits the title, so a stack never ends up pointing at a photo that no
    /// longer exists.
    func removing(_ removed: Set<PhotoAsset.ID>) -> PhotoStack? {
        guard !removed.isEmpty else { return self }
        let remaining = assets.filter { !removed.contains($0.id) }
        guard remaining.count > 1 else { return nil }

        let ranked = rankedAssetIDs.filter { !removed.contains($0) }
        let best = removed.contains(bestShotID) ? (ranked.first ?? remaining[0].id) : bestShotID

        return PhotoStack(
            id: id,
            assets: remaining,
            bestShotID: best,
            rankedAssetIDs: ranked,
            assetsPreselectedForDeletion: assetsPreselectedForDeletion.subtracting(removed)
        )
    }
}
