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
        /// Never contains `bestShotID` — the initialiser strips it, and every
        /// mutator preserves that. See the note on the initialiser.
        private(set) var checkedForDeletion: Set<PhotoAsset.ID>

        /// Strips the best shot from the deletion set, always.
        ///
        /// `PhotoStack.init` already does this, but `PhotoStack` is not the type
        /// the UI binds to — this is. An audit found the gap: `removeDeleted`
        /// re-elects `ranked.first` when the old best shot is deleted, and in a
        /// burst that next-highest-scored photo is very often one of the
        /// pre-checked extras. Nothing subtracted it, so it could end up starred
        /// as the best shot AND still in `assetsToDelete` — and because the tile
        /// hides the delete toggle for the best shot, the user had no way to
        /// untick it.
        ///
        /// Enforcing it here rather than at each call site means a future
        /// mutator cannot reintroduce the bug by forgetting.
        init(
            id: UUID,
            assets: [PhotoAsset],
            rankedIDs: [PhotoAsset.ID],
            bestShotID: PhotoAsset.ID,
            checkedForDeletion: Set<PhotoAsset.ID>
        ) {
            self.id = id
            self.assets = assets
            self.rankedIDs = rankedIDs
            self.bestShotID = bestShotID
            self.checkedForDeletion = checkedForDeletion.subtracting([bestShotID])
        }

        func asset(_ id: PhotoAsset.ID) -> PhotoAsset? { assets.first { $0.id == id } }

        // MARK: Mutation, each preserving "best is never checked"

        mutating func check(_ id: PhotoAsset.ID) {
            guard id != bestShotID else { return }
            checkedForDeletion.insert(id)
        }

        mutating func uncheck(_ id: PhotoAsset.ID) {
            checkedForDeletion.remove(id)
        }

        mutating func setChecked(_ ids: Set<PhotoAsset.ID>) {
            checkedForDeletion = ids.subtracting([bestShotID])
        }

        mutating func clearChecks() {
            checkedForDeletion.removeAll()
        }

        /// Promotes a new best shot, unchecking it in the same step so the two
        /// can never disagree.
        mutating func promote(toBestShot id: PhotoAsset.ID) {
            bestShotID = id
            checkedForDeletion.remove(id)
        }
    }

    private(set) var stacks: [Stack]

    /// On-disk byte size per asset id, populated once via `loadSizes`.
    private(set) var assetSizes: [PhotoAsset.ID: Int64] = [:]

    init(stacks: [PhotoStack]) {
        self.stacks = stacks.map(Self.freshStack)
    }

    /// A review stack built from the scan's defaults, with nothing edited yet.
    private static func freshStack(from stack: PhotoStack) -> Stack {
        Stack(
            id: stack.id,
            assets: stack.assets,
            rankedIDs: stack.rankedAssetIDs,
            bestShotID: stack.bestShotID,
            checkedForDeletion: stack.assetsPreselectedForDeletion
        )
    }

    /// Brings the model in line with a new set of stacks while keeping every
    /// choice the user has already made.
    ///
    /// The problem this solves: `PhotoStack.id` is a fresh `UUID` on each
    /// rebuild, so it can't be used to recognise a group across rebuilds. But a
    /// group's *membership* — the set of asset ids in it — is stable, and
    /// uniquely identifies it (asset ids are globally unique). So edits are
    /// matched by membership: a stack whose members are unchanged keeps its
    /// ticks and its chosen best shot; a genuinely new or changed group gets the
    /// scan's default suggestion.
    ///
    /// This runs on every `stacks` change on the coordinator, which is what lets
    /// the review screen grow with a progressive scan and survive a background
    /// re-cluster without ever resetting the user's work.
    func reconcile(with photoStacks: [PhotoStack]) {
        func membershipKey(_ ids: [PhotoAsset.ID]) -> String {
            ids.sorted().joined(separator: "|")
        }

        // Index the user's current edits by membership. `uniquingKeysWith`
        // rather than the trapping initialiser: two stacks can't normally share
        // a member, but a crash would be a steep price for that assumption.
        let edited = Dictionary(
            stacks.map { (membershipKey($0.assets.map(\.id)), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        stacks = photoStacks.map { incoming in
            guard let prior = edited[membershipKey(incoming.assets.map(\.id))] else {
                return Self.freshStack(from: incoming)   // new or changed group
            }
            // Same group, seen before — carry the edits forward, clamped to the
            // assets that still exist (belt-and-braces: identical membership
            // means the clamp is a no-op, but it can't hurt and guards the day
            // membership drifts without changing the key).
            let live = Set(incoming.assets.map(\.id))
            return Stack(
                id: incoming.id,
                assets: incoming.assets,
                rankedIDs: incoming.rankedAssetIDs,
                bestShotID: live.contains(prior.bestShotID) ? prior.bestShotID : incoming.bestShotID,
                checkedForDeletion: prior.checkedForDeletion.intersection(live)
            )
        }
    }

    // MARK: - Derived totals (for the confirmation bar)

    var totalPhotosToDelete: Int {
        stacks.reduce(0) { $0 + $1.checkedForDeletion.count }
    }

    var hasSelection: Bool { totalPhotosToDelete > 0 }

    /// Every asset id the user has confirmed for deletion, across all stacks.
    ///
    /// Subtracts the best shot again even though `Stack` already guarantees it.
    /// This is the last expression before ids reach `deleteAssets`, and the cost
    /// of the redundancy is one set operation per stack; the cost of being wrong
    /// is deleting the photo the app told the user it was keeping. `PhotoStack`
    /// makes the same trade for the same reason.
    var assetsToDelete: [PhotoAsset.ID] {
        stacks.flatMap { $0.checkedForDeletion.subtracting([$0.bestShotID]) }
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
        let sizes = await library.fileSizes(for: unknown).sizes
        assetSizes.merge(sizes) { _, new in new }
    }

    // MARK: - Edits

    /// Toggle a photo's deletion checkbox. The best shot cannot be checked.
    func toggleDeletion(of assetID: PhotoAsset.ID, inStack stackID: UUID) {
        guard let i = stacks.firstIndex(where: { $0.id == stackID }) else { return }
        guard assetID != stacks[i].bestShotID else { return }   // best shot is protected
        if stacks[i].checkedForDeletion.contains(assetID) {
            stacks[i].uncheck(assetID)
        } else {
            stacks[i].check(assetID)
        }
    }

    /// Promote a photo to "best shot". It's removed from the deletion set, since
    /// the best shot is never deletable.
    func setBestShot(_ assetID: PhotoAsset.ID, inStack stackID: UUID) {
        guard let i = stacks.firstIndex(where: { $0.id == stackID }) else { return }
        stacks[i].promote(toBestShot: assetID)
    }

    /// Check every non-best photo in a stack (a "select all extras" convenience).
    func checkAllExtras(inStack stackID: UUID) {
        guard let i = stacks.firstIndex(where: { $0.id == stackID }) else { return }
        stacks[i].setChecked(Set(stacks[i].assets.map(\.id)))
    }

    /// Clear all deletion checks in a stack (keep everything **this time**).
    ///
    /// View-local and deliberately not persisted — "not now" rather than "not
    /// ever". `ReviewScreen.neverSuggest(_:)` is the durable counterpart.
    func clearChecks(inStack stackID: UUID) {
        guard let i = stacks.firstIndex(where: { $0.id == stackID }) else { return }
        stacks[i].clearChecks()
    }

    /// Remove a whole stack from the review list, after the user has said it
    /// should never be suggested again.
    func removeStack(_ stackID: UUID) {
        stacks.removeAll { $0.id == stackID }
    }

    /// The photos that will REMAIN in every stack this deletion touches — the
    /// ones the user chose to keep by not checking them.
    ///
    /// Stacks the deletion doesn't touch are excluded: leaving a group alone is
    /// not a decision about it, and shouldn't be recorded as one.
    ///
    /// Must be called **before** `removeDeleted(_:)`, which mutates `stacks`.
    func survivors(ofStacksAffectedBy deletedIDs: [PhotoAsset.ID]) -> [PhotoAsset.ID] {
        let removed = Set(deletedIDs)
        return stacks.flatMap { stack -> [PhotoAsset.ID] in
            let ids = stack.assets.map(\.id)
            guard ids.contains(where: { removed.contains($0) }) else { return [] }
            return ids.filter { !removed.contains($0) }
        }
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
