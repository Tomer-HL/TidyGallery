//
//  PhotoAsset.swift
//  TidyGallery
//
//  The app's own `Sendable`, `Identifiable` representation of a photo.
//
//  IMPORTANT (Swift 6 concurrency): `PHAsset` is a non-`Sendable` reference
//  type owned by the Photos framework. We never pass it across actor
//  boundaries. Instead we snapshot the fields we need into this value type at
//  fetch time, and re-resolve the live `PHAsset` by `localIdentifier` on the
//  library actor only when we actually need pixels or to perform a deletion.
//
//  Location is stored as plain `Double` latitude/longitude rather than a
//  `CLLocationCoordinate2D`, so the whole struct is trivially `Sendable`
//  without any retroactive conformance on a Foundation/CoreLocation type.
//

import Foundation
import CoreLocation

/// A lightweight, thread-safe snapshot of one photo-library asset plus its
/// (optional) analysis results.
struct PhotoAsset: Identifiable, Sendable, Hashable {

    // MARK: Identity

    /// Stable identity used everywhere: SwiftUI, the cache, and to re-fetch the
    /// live `PHAsset`. This is `PHAsset.localIdentifier`.
    let id: String

    // MARK: Snapshotted metadata (cheap, safe to carry)

    let creationDate: Date?
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let latitude: Double?
    let longitude: Double?

    // MARK: Analysis results (populated by the pipeline; nil until analysed)

    /// Visual embedding used for clustering. `nil` until analysed.
    var featurePrint: FeaturePrint?

    /// Quality breakdown used for best-shot ranking. `nil` until analysed.
    var score: ShotScore?

    /// Memberwise-style init that still accepts a `CLLocationCoordinate2D` at the
    /// call site (convenient when snapshotting a `PHAsset`) but stores only
    /// primitives internally.
    init(
        id: String,
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        isFavorite: Bool,
        coordinate: CLLocationCoordinate2D?,
        featurePrint: FeaturePrint? = nil,
        score: ShotScore? = nil
    ) {
        self.id = id
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
        self.latitude = coordinate?.latitude
        self.longitude = coordinate?.longitude
        self.featurePrint = featurePrint
        self.score = score
    }

    // MARK: Derived

    /// Whether analysis has completed for this asset.
    var isAnalysed: Bool { featurePrint != nil && score != nil }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation? {
        guard let latitude, let longitude else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Identity-based equality

extension PhotoAsset {
    static func == (lhs: PhotoAsset, rhs: PhotoAsset) -> Bool {
        lhs.id == rhs.id
            && lhs.modificationDate == rhs.modificationDate
            && lhs.featurePrint == rhs.featurePrint
            && lhs.score == rhs.score
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(modificationDate)
    }
}
