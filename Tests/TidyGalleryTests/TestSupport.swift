//
//  TestSupport.swift
//  TidyGalleryTests
//
//  Builders and small helpers so tests read as intent, not boilerplate.
//  Uses Swift Testing (`import Testing`), the modern iOS 18 test framework.
//

import Foundation
import CoreLocation
@testable import TidyGallery

// MARK: - Float comparison

/// Approximate equality for the float/double math in scoring and distance.
func isClose(_ a: Double, _ b: Double, tol: Double = 1e-4) -> Bool {
    abs(a - b) <= tol
}

func isClose(_ a: Float, _ b: Float, tol: Float = 1e-4) -> Bool {
    abs(a - b) <= tol
}

// MARK: - Builders

extension ShotScore {
    /// A face-less score parameterised by the two knobs the tests exercise.
    static func plain(sharpness: Double, aesthetics: Double? = nil, favorite: Bool = false) -> ShotScore {
        ShotScore(
            sharpness: sharpness,
            aesthetics: aesthetics,
            faceQuality: .noFaces,
            isFavorite: favorite
        )
    }
}

extension PhotoAsset {
    /// Compact builder. Defaults produce a valid, analysable asset.
    static func make(
        id: String,
        secondsFromEpoch: TimeInterval = 0,
        favorite: Bool = false,
        coordinate: CLLocationCoordinate2D? = nil,
        featurePrint: FeaturePrint? = nil,
        score: ShotScore? = nil
    ) -> PhotoAsset {
        let date = Date(timeIntervalSince1970: secondsFromEpoch)
        return PhotoAsset(
            id: id,
            creationDate: date,
            modificationDate: date,
            pixelWidth: 4000,
            pixelHeight: 3000,
            isFavorite: favorite,
            coordinate: coordinate,
            featurePrint: featurePrint,
            score: score
        )
    }
}

/// Convenience: index assets by id, as the scorer expects.
func indexed(_ assets: [PhotoAsset]) -> [PhotoAsset.ID: PhotoAsset] {
    Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
}
