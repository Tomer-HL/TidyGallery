//
//  StorageSummaryBuilder.swift
//  TidyGallery
//
//  Turns the space-heavy category id sets plus measured file sizes into the
//  dashboard's `StorageSummary`.
//
//  Extracted from the coordinator because the interesting part is easy to get
//  subtly wrong: categories OVERLAP (a big screenshot is both a screenshot and a
//  big file; an exact duplicate may also sit in a visual duplicate group), so
//  the headline total must be computed over the DE-DUPLICATED union while each
//  line item is reported on its own ids. Summing the line items would
//  double-count and overstate what the user can actually reclaim.
//

import Foundation

struct StorageSummaryBuilder {

    /// The id sets that make up reclaimable space.
    struct Input: Sendable {
        var exactDuplicateIDs: Set<String> = []
        var duplicateIDs: Set<String> = []
        var videoIDs: Set<String> = []
        var bigFileIDs: Set<String> = []
        var recordingIDs: Set<String> = []
        var screenshotIDs: Set<String> = []

        /// Every id that contributes to reclaimable space, counted once.
        var unionIDs: Set<String> {
            exactDuplicateIDs
                .union(duplicateIDs)
                .union(videoIDs)
                .union(bigFileIDs)
                .union(recordingIDs)
                .union(screenshotIDs)
        }

        var isEmpty: Bool { unionIDs.isEmpty }
    }

    /// Builds the summary. Assets with no measured size contribute zero bytes
    /// but still count toward their category's item count.
    static func build(_ input: Input, sizes: [String: Int64]) -> StorageSummary {
        guard !input.isEmpty else { return .empty }

        func bytes<S: Sequence>(_ ids: S) -> Int64 where S.Element == String {
            ids.reduce(0) { $0 + (sizes[$1] ?? 0) }
        }
        func item(_ ids: Set<String>) -> StorageSummary.LineItem {
            .init(count: ids.count, bytes: bytes(ids))
        }

        return StorageSummary(
            reclaimableBytes: bytes(input.unionIDs),   // de-duplicated, not a sum of lines
            exactDuplicates: item(input.exactDuplicateIDs),
            duplicates: item(input.duplicateIDs),
            largeVideos: item(input.videoIDs),
            bigFiles: item(input.bigFileIDs),
            screenRecordings: item(input.recordingIDs),
            screenshots: item(input.screenshotIDs)
        )
    }
}
