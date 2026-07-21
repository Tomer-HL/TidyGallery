//
//  ClassificationLabel.swift
//  TidyGallery
//
//  A single label Vision's image classifier assigned to a photo, kept so the
//  "Why this photo?" sheet can show exactly what the classifier saw.
//
//  This exists mainly to make category bugs self-diagnosing: instead of guessing
//  why a photo landed in the wrong category and rebuilding to find out, the user
//  can long-press it and read "child 0.42, cat 0.17" directly.
//

import Foundation

struct ClassificationLabel: Sendable, Hashable, Codable, Identifiable {
    let identifier: String
    let confidence: Float

    var id: String { identifier }

    /// Human-friendly label: Vision identifiers use underscores ("hot_dog").
    var displayName: String {
        identifier.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
