//
//  StorageSummary.swift
//  TidyGallery
//
//  A value-type snapshot of how much space the user could reclaim, broken down
//  by the space-heavy cleanup categories. Computed by the scan coordinator and
//  rendered by the home dashboard. Content categories (food, pets, ...) are
//  about organisation, not space, so they're intentionally excluded here.
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

    var duplicates: LineItem
    var largeVideos: LineItem
    var bigFiles: LineItem
    var screenRecordings: LineItem

    static let empty = StorageSummary(
        reclaimableBytes: 0,
        duplicates: .zero,
        largeVideos: .zero,
        bigFiles: .zero,
        screenRecordings: .zero
    )

    /// Whether there's anything worth showing in the dashboard.
    var hasReclaimableSpace: Bool { reclaimableBytes > 0 }
}
