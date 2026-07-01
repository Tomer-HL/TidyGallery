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
    let coordinate: CLLocationCoordinate2D?

    // MARK: Analysis results (populated by the pipeline; nil until analysed)

    /// Visual embedding used for clustering. `nil` until analysed.
    var featurePrint: FeaturePrint?

    /// Quality breakdown used for best-shot ranking. `nil` until analysed.
    var score: ShotScore?

    /// Whether analysis has completed for this asset.
    var isAnalysed: Bool { featurePrint != nil && score != nil }

    var location: CLLocation? {
        coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

// CLLocationCoordinate2D isn't Hashable/Sendable by default; conform minimally
// so PhotoAsset can be Hashable and Sendable without warnings.
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

// CLLocationCoordinate2D is a plain C struct of two Doubles and is safe to send.
extension CLLocationCoordinate2D: @retroactive @unchecked Sendable {}
