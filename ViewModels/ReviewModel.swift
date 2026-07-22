//
//  ReviewModel.swift
//  TidyGallery
//
//  Editable review state derived from the analyzer's immutable `[PhotoStack]`.
//  The engine only ever *recommends*; this model holds the user's live edits —
//  which photos are checked for deletion and which is the best shot — and is the
//  single source of truth the UI binds to.
//
//  Safety rules enforced here (Phase 1's promises, now user-facing):
//   • The current best shot can never be checked for deletion.
//   • Promoting a new best shot automatically un-checks it.
//   • Nothing leaves this model for deletion without an explicit user tap on the
//     confirm button (see `assetsToDelete`).
//

import Foundation
import Observation

@MainActor
@Observable
final class ReviewModel {

    /// One stack's mutable review state.
    struct Stack: Identifiable {
        let id: UUID
        let assets: [PhotoAsset]
        /// Display order, best → worst (from the scorer).
        let rankedIDs: [PhotoAsset.ID]
        var bestShotID: PhotoAsset.ID
        var checkedForDeletion: Set<PhotoAsset.ID>

        func asset(_ id: PhotoAsset.ID) -> PhotoAsset? { assets.first { $0.id == id } }
    }

    private(set) var stacks: [Stack]

    /// On-disk byte size per asset id, populated once via `loadSizes`.
    private(set) var assetSizes: [PhotoAsset.ID: Int64] = [:]

    init(stacks: [PhotoStack]) {
        self.stacks = stacks.map { stack in
            Stack(
                id: stack.id,
                assets: stack.assets,
                rankedIDs: stack.rankedAssetIDs,
                bestShotID: stack.bestShotID,
                checkedForDeletion: stack.assetsPreselectedForDeletion
            )
        }
    }

    // MARK: - Derived totals (for the confirmation bar)

    var totalPhotosToDelete: Int {
        stacks.reduce(0) { $0 + $1.checkedForDeletion.count }
    }

    var hasSelection: Bool { totalPhotosToDelete > 0 }

    /// Every asset id the user has confirmed for deletion, across all stacks.
    var assetsToDelete: [PhotoAsset.ID] {
        stacks.flatMap { Array($0.checkedForDeletion) }
    }

    // MARK: - Reclaimable space

    /// Bytes freed if the checked photos in one stack are deleted.
    func bytesToFree(inStack stackID: UUID) -> Int64 {
        guard let stack = stacks.first(where: { $0.id == stackID }) else { return 0 }
        return stack.checkedForDeletion.reduce(0) { $0 + (assetSizes[$1] ?? 0) }
    }

    /// Bytes freed across the whole current selection.
    var totalBytesToFree: Int64 {
        stacks.reduce(0) { total, stack in
            total + stack.checkedForDeletion.reduce(0) { $0 + (assetSizes[$1] ?? 0) }
        }
    }

    /// Fetch on-disk sizes for every asset in the review, once. Cheap metadata
    /// lookup batched into a single query; safe to call again (skips known ids).
    func loadSizes(using library: PhotoLibraryService) async {
        let unknown = stacks
            .flatMap { $0.assets.map(\.id) }
            .filter { assetSizes[$0] == nil }
        guard !unknown.isEmpty else { return }
        let sizes = library.fileSizes(for: unknown)
        assetSizes.merge(sizes) { _, new in new }
    }

    // MARK: - Edits

    /// Toggle a photo's deletion checkbox. The best shot cannot be checked.
    func toggleDeletion(of assetID: PhotoAsset.ID, inStack stackID: UUID) {
        guard let i = stacks.firstIndex(where: { $0.id == stackID }) else { return }
        guard assetID != stacks[i].bestShotID else { return }   // best shot is protected
        if stacks[i].checkedForDeletion.contains(assetID) {
            stacks[i].checkedForDeletion.remove(assetID)
        } else {
            stacks[i].checkedForDeletion.insert(assetID)
        }
    }

    /// Promote a photo to "best shot". It's removed from the deletion set, since
    /// the best shot is never deletable.
    func setBestShot(_ assetID: PhotoAsset.ID, inStack stackID: UUID) {
        guard let i = stacks.firstIndex(where: { $0.id == stackID }) else { return }
        stacks[i].bestShotID = assetID
        stacks[i].checkedForDeletion.remove(assetID)
    }

    /// Check every non-best photo in a stack (a "select all extras" convenience).
    func checkAllExtras(inStack stackID: UUID) {
        guard let i = stacks.firstIndex(where: { $0.id == stackID }) else { return }
        let extras = stacks[i].assets.map(\.id).filter { $0 != stacks[i].bestShotID }
        stacks[i].checkedForDeletion = Set(extras)
    }

    /// Clear all deletion checks in a stack (keep everything **this time**).
    ///
    /// View-local and deliberately not persisted — "not now" rather than "not
    /// ever". `ReviewScreen.neverSuggest(_:)` is the durable counterpart.
    func clearChecks(inStack stackID: UUID) {
        guard let i = stacks.firstIndex(where: { $0.id == stackID }) else { return }
        stacks[i].checkedForDeletion.removeAll()
    }

    /// Remove a whole stack from the review list, after the user has said it
    /// should never be suggested again.
    func removeStack(_ stackID: UUID) {
        stacks.removeAll { $0.id == stackID }
    }

    // MARK: - Post-deletion

    /// After a successful deletion, drop the removed assets. Stacks that fall to
    /// a single photo (or none) are removed entirely — they're no longer a
    /// cleanup opportunity.
    func removeDeleted(_ deletedIDs: [PhotoAsset.ID]) {
        let removed = Set(deletedIDs)
        stacks = stacks.compactMap { stack in
            let remaining = stack.assets.filter { !removed.contains($0.id) }
            guard remaining.count > 1 else { return nil }
            let ranked = stack.rankedIDs.filter { !removed.contains($0) }
            let best = removed.contains(stack.bestShotID) ? (ranked.first ?? remaining[0].id) : stack.bestShotID
            return Stack(
                id: stack.id,
                assets: remaining,
                rankedIDs: ranked,
                bestShotID: best,
                checkedForDeletion: stack.checkedForDeletion.subtracting(removed)
            )
        }
    }
}
