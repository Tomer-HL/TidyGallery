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
                && !isSharpButLowTexture(asset)
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

    /// Whether a photo is low-sharpness because of its CONTENT, not its focus —
    /// the two things variance-of-Laplacian can't tell apart.
    ///
    /// Two independent signals, either of which is enough to spare a photo from
    /// "possibly blurry":
    ///
    ///   - It's a nature/scenery scene. Sunsets, skies and landscapes are smooth
    ///     by nature and score low on Laplacian sharpness while being in perfect
    ///     focus. (Refined tags, so a scenic shot WITH a person in it isn't
    ///     spared on these grounds — but such a photo has texture from the person
    ///     anyway.)
    ///   - The aesthetics model rates it well. A blurry photo is an unpleasant
    ///     one; a good-looking photo is not what the user means by blurry.
    private func isSharpButLowTexture(_ asset: PhotoAsset) -> Bool {
        let hasFaces = (asset.score?.faceQuality.faceCount ?? 0) > 0
        let tags = SceneCategory.refined(
            from: asset.classificationLabels,
            hasFaces: hasFaces,
            relativeFloor: config.categoryConfidenceRelativeFloor,
            absoluteFloor: config.categoryConfidenceAbsoluteFloor
        )
        if tags.contains(.nature) { return true }

        if let aesthetics = asset.score?.aesthetics,
           aesthetics >= config.blurryExcludeAestheticsAtOrAbove {
            return true
        }
        return false
    }
}
