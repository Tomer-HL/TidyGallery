//
//  CachedAssetSize.swift
//  TidyGallery
//
//  SwiftData model caching one asset's on-disk byte size.
//
//  Why this exists
//  ---------------
//  Diagnostics from a real device, on a library where analysis was 100% cached:
//
//      Size measurement   1.7 s   (199 assets, 8.8 ms each)
//      Metadata pass      936 ms  (199 assets, 4.7 ms each)
//      Vision analysis    0 ms    (every photo served from CachedAnalysis)
//
//  A scan that did no image work at all still cost 2.7 seconds, all of it in
//  `PHAssetResource.assetResources(for:)` — the only way to read a file size,
//  and an expensive one. Extrapolated to the 20,000-photo library this app is
//  designed for, that is roughly three minutes of resource walking on EVERY
//  launch, recomputing numbers that cannot have changed.
//
//  Feature prints were cached from the start because they were obviously
//  expensive. File sizes were not, because reading a number felt cheap. The
//  measurement says otherwise, and the fix is the one already proven for
//  analysis: persist the result, key it on `modificationDate`, recompute only
//  what actually changed.
//
//  Staleness
//  ---------
//  `PHAsset.modificationDate` is the same signal `CachedAnalysis` uses, and it
//  moves whenever an edit is applied — which is precisely when a new adjusted
//  resource appears and the on-disk total changes. It also moves on a favorite
//  toggle, which does NOT change size; that costs one needless re-measure and is
//  the safe direction to be wrong in.
//
//  Deliberately NOT keyed on iCloud residency: `PHAssetResource.fileSize`
//  reports the original's size whether or not the bytes are local, so a photo
//  evicted by "Optimize iPhone Storage" keeps a stable, correct size.
//

import Foundation
import SwiftData

/// Persisted on-disk size for a single asset, keyed by `PHAsset.localIdentifier`.
@Model
final class CachedAssetSize {

    /// Bumped if the definition of "size" ever changes (e.g. counting only the
    /// original resource rather than every resource). Rows from an older
    /// version are treated as stale and re-measured once.
    ///   v1 → sum of every `PHAssetResource` (original + edited render)
    static let currentSchemaVersion = 1

    /// `PHAsset.localIdentifier`. Unique so we can upsert by identity.
    @Attribute(.unique) var localIdentifier: String

    /// The asset's modification date when the size was measured. A mismatch
    /// against the live asset means this row is stale.
    var measuredModificationDate: Date?

    /// Total bytes across every resource of the asset — what deleting it frees.
    var bytes: Int64

    /// Which measurement version produced this row (see `currentSchemaVersion`).
    /// Defaulted so any pre-existing row migrates to 0 and is refreshed.
    var schemaVersion: Int = 0

    /// When this row was written (for debugging).
    var updatedAt: Date

    init(
        localIdentifier: String,
        measuredModificationDate: Date?,
        bytes: Int64,
        schemaVersion: Int = CachedAssetSize.currentSchemaVersion,
        updatedAt: Date = .now
    ) {
        self.localIdentifier = localIdentifier
        self.measuredModificationDate = measuredModificationDate
        self.bytes = bytes
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
    }

    /// Whether this row is still valid for an asset with the given modification
    /// date — the date must match AND the row must come from the current
    /// measurement version.
    func isFresh(for modificationDate: Date?) -> Bool {
        measuredModificationDate == modificationDate
            && schemaVersion == Self.currentSchemaVersion
    }
}
