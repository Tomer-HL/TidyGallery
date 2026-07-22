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
//  A separate *entity* turned out not to be enough. Entities in one SwiftData
//  store share a single file, and the cache container's recovery path deletes
//  that file outright to survive a migration failure — taking every ignore
//  decision with it. These rows now live in their own store (`IgnoreList.store`,
//  built in `TidyGalleryApp.makeIgnoreContainer()`), which is what actually
//  makes the guarantee above true rather than merely intended.
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
