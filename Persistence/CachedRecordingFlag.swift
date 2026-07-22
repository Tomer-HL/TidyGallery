//
//  CachedRecordingFlag.swift
//  TidyGallery
//
//  Caches whether a video is a screen recording, so the answer is derived once
//  per video instead of on every launch.
//
//  Why this exists
//  ---------------
//  Device diagnostics, 8,756 stills and 1,526 videos, cold:
//
//      Metadata pass              5.03 s
//      └ Videos + recordings      5.03 s   (1,526 videos, 3.29 ms each)
//        └ recording filename walk 4.87 s  (1,526 videos, 3.19 ms each)
//
//  Ninety-seven percent of the metadata pass is one call. Everything else in
//  that pass is rounding error by comparison — screenshots 130 ms, selfies
//  175 ms, big-file candidates 302 ms. And it is paid on *every* launch,
//  because iOS exposes no smart-album subtype for screen recordings, so the
//  only way to identify one is `PHAssetResource.assetResources(for:)` and a
//  check for ReplayKit's `RPReplay_Final…` filename.
//
//  The on-disk size cache cannot help: it stores `fileSize`, and this needs
//  `originalFilename` — same expensive call, different field.
//
//  Keyed on identifier alone, with no modification date
//  ---------------------------------------------------
//  Unlike `CachedAssetSize`, this has no staleness rule, because the thing it
//  records cannot change. A video's original filename is fixed at capture;
//  editing a video adds an adjusted resource but does not rename the original,
//  and `PHAsset.localIdentifier` is never reused. So a row here is valid for as
//  long as the asset exists.
//
//  That is also why it is a separate model rather than a field on
//  `CachedAssetSize`. Sharing that row would inherit its `modificationDate`
//  staleness rule, and something as innocuous as favouriting a video would
//  discard a fact that had not changed — reintroducing the walk this exists to
//  avoid, for no reason.
//

import Foundation
import SwiftData

/// Whether one asset is a screen recording, keyed by `PHAsset.localIdentifier`.
@Model
final class CachedRecordingFlag {

    /// Bumped when the *detection rule* changes, as opposed to the asset.
    ///
    /// Having no staleness rule for the asset is right — the filename cannot
    /// change. But that argument says nothing about our own code being wrong,
    /// and without a version there would be no way to invalidate anything: if
    /// the heuristic ever broadens past `RPReplay`, or a bug writes bad flags,
    /// every installed copy keeps its old answers permanently. Both sibling
    /// caches carry this for the same reason.
    ///   v1 → `originalFilename` has the `RPReplay` prefix
    static let currentSchemaVersion = 1

    /// `PHAsset.localIdentifier`. Unique so we can upsert by identity.
    @Attribute(.unique) var localIdentifier: String

    /// True when the asset's original filename carries ReplayKit's prefix.
    var isScreenRecording: Bool

    /// Which detection rule produced this row. Defaulted so any pre-existing
    /// row migrates to 0 and is re-derived once.
    var schemaVersion: Int = 0

    /// When this row was written. Diagnostics only.
    var updatedAt: Date

    init(
        localIdentifier: String,
        isScreenRecording: Bool,
        schemaVersion: Int = CachedRecordingFlag.currentSchemaVersion,
        updatedAt: Date = .now
    ) {
        self.localIdentifier = localIdentifier
        self.isScreenRecording = isScreenRecording
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
    }

    /// Whether this row was produced by the current detection rule.
    var isFresh: Bool { schemaVersion == Self.currentSchemaVersion }
}
