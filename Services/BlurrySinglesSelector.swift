//
//  BlurrySinglesSelector.swift
//  TidyGallery
//
//  Chooses which standalone photos are surfaced as "possibly blurry".
//
//  Extracted from the scan coordinator so the rule is testable in isolation —
//  it's the subtlest derivation in the app. Sharpness (Laplacian variance) has
//  no absolute meaning across devices and downscales, so a fixed cutoff either
//  flags everything or nothing. The rule is therefore RELATIVE and bounded:
//
//    surfaced  =  sharpness <= min(library low-percentile, absolute ceiling)
//                 capped at `blurryMaxCount`
//
//  which means it can never become a dumping ground even if every photo scores
//  low. It is surfacing-only: nothing here is ever pre-selected for deletion.
//

import Foundation

struct BlurrySinglesSelector {

    let config: AnalysisConfiguration

    init(config: AnalysisConfiguration = .default) {
        self.config = config
    }

    /// - Parameters:
    ///   - assets: the analysed working set.
    ///   - excluding: ids to skip — photos already shown in a duplicate group,
    ///     and anything the user asked us to stop suggesting.
    func select(
        from assets: [PhotoAsset],
        excluding excludedIDs: Set<PhotoAsset.ID> = []
    ) -> [PhotoAsset] {
        let eligible = assets.filter { asset in
            asset.mediaType == .image
                && !asset.isFavorite
                && !excludedIDs.contains(asset.id)
                && asset.score != nil
        }
        guard !eligible.isEmpty else { return [] }

        // Relative floor: sharpness at the configured low percentile.
        let sortedSharpness = eligible.compactMap { $0.score?.sharpness }.sorted()
        let index = Int(Double(sortedSharpness.count - 1) * config.blurryPercentile)
        let percentileFloor = sortedSharpness[max(0, min(index, sortedSharpness.count - 1))]

        // Must be below BOTH the relative floor and the absolute ceiling.
        let cutoff = min(percentileFloor, config.blurrySinglesSharpnessCeiling)

        return eligible
            .filter { ($0.score?.sharpness ?? 1) <= cutoff }
            .sorted { ($0.score?.sharpness ?? 0) < ($1.score?.sharpness ?? 0) }
            .prefix(config.blurryMaxCount)
            .map { $0 }
    }
}
