//
//  StorageSummary.swift
//  TidyGallery
//
//  A value-type snapshot of how much space the user could reclaim, broken down
//  by the space-heavy cleanup categories. Computed by the scan coordinator and
//  rendered by the home dashboard. Purely-organisational categories (food, pets,
//  nature, selfies) are intentionally excluded: they overlap heavily with each
//  other and with the space categories, and clearing them isn't a space decision.
//
//  Note on duplicates: this counts the *potential* saving (every photo in a
//  group except its best shot), because the dashboard is framed as "up to X
//  reclaimable". The much smaller conservative subset the engine actually
//  pre-selects is what "Recommended cleanup" acts on.
//

import Foundation

struct StorageSummary: Sendable, Equatable {

    /// One dashboard line: how many items and how many bytes they occupy.
    struct LineItem: Sendable, Equatable {
        var count: Int
        var bytes: Int64
        static let zero = LineItem(count: 0, bytes: 0)
    }

    /// Total reclaimable bytes across the space categories, de-duplicated so an
    /// asset counted in two categories (e.g. a big screenshot) isn't summed twice.
    var reclaimableBytes: Int64

    /// Redundant copies of byte-identical images — the highest-confidence
    /// reclaimable space, since one copy is always kept.
    var exactDuplicates: LineItem

    var duplicates: LineItem
    var largeVideos: LineItem
    var bigFiles: LineItem
    var screenRecordings: LineItem
    var screenshots: LineItem

    static let empty = StorageSummary(
        reclaimableBytes: 0,
        exactDuplicates: .zero,
        duplicates: .zero,
        largeVideos: .zero,
        bigFiles: .zero,
        screenRecordings: .zero,
        screenshots: .zero
    )

    /// Whether there's anything worth showing in the dashboard.
    var hasReclaimableSpace: Bool { reclaimableBytes > 0 }
}
