//
//  IgnoredAsset.swift
//  TidyGallery
//
//  A photo the user has explicitly decided to keep ("never suggest this again").
//
//  This is a deliberate, separate entity from `CachedAnalysis`. The analysis
//  cache is disposable and gets invalidated wholesale whenever the pipeline
//  gains a new output (schemaVersion bumps) — user decisions must NEVER be lost
//  that way, so they live in their own table with no version coupling.
//

import Foundation
import SwiftData

@Model
final class IgnoredAsset {

    /// `PHAsset.localIdentifier`. Unique so ignoring twice is idempotent.
    @Attribute(.unique) var localIdentifier: String

    /// When the user chose to ignore it (for a future "recently ignored" view).
    var ignoredAt: Date

    init(localIdentifier: String, ignoredAt: Date = .now) {
        self.localIdentifier = localIdentifier
        self.ignoredAt = ignoredAt
    }
}
