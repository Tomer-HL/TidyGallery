//
//  CleanupCategory.swift
//  TidyGallery
//
//  Presentation descriptor for a "flat list" cleanup category (screenshots,
//  large videos, big files, screen recordings, possibly-blurry singles). Keeping
//  copy, icons, and per-category behaviour in one value type lets a single
//  reusable screen (`AssetCleanupScreen`) render every category consistently.
//
//  Duplicates/bursts are NOT modelled here — they have their own best-shot
//  workflow in `ReviewScreen`.
//

import Foundation

/// Describes how one standalone cleanup category looks and behaves.
struct CleanupCategory: Identifiable, Hashable {

    enum Kind: String, Hashable {
        case screenshots
        case largeVideos
        case bigFiles
        case screenRecordings
        case blurry
    }

    let kind: Kind
    var id: Kind { kind }

    /// Navigation title, e.g. "Large videos".
    let title: String
    /// Row/tab SF Symbol.
    let systemImage: String
    /// Singular noun for counts and buttons, e.g. "video".
    let noun: String
    /// One-line description shown on the home card.
    let blurb: String

    /// Empty-state title + subtitle when the category has no items.
    let emptyTitle: String
    let emptySubtitle: String

    /// Whether tiles should decorate items as video (play glyph + duration).
    let isVideo: Bool
    /// Whether items should be sorted largest-file-first once sizes are measured.
    let sortsBySizeDescending: Bool
    /// Optional cap on how many items to display after sorting (nil = all).
    let displayLimit: Int?

    // MARK: Presets

    static let screenshots = CleanupCategory(
        kind: .screenshots,
        title: "Screenshots",
        systemImage: "camera.viewfinder",
        noun: "screenshot",
        blurb: "Screen grabs you probably don't need anymore",
        emptyTitle: "No screenshots",
        emptySubtitle: "You don't have any screenshots to clean up right now.",
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil
    )

    static let largeVideos = CleanupCategory(
        kind: .largeVideos,
        title: "Large videos",
        systemImage: "film.stack",
        noun: "video",
        blurb: "Videos take the most space — biggest first",
        emptyTitle: "No videos",
        emptySubtitle: "There are no videos in your library to review.",
        isVideo: true,
        sortsBySizeDescending: true,
        displayLimit: nil
    )

    static let bigFiles = CleanupCategory(
        kind: .bigFiles,
        title: "Big files",
        systemImage: "internaldrive",
        noun: "photo",
        blurb: "Your largest photos and Live Photos",
        emptyTitle: "Nothing oversized",
        emptySubtitle: "We didn't find unusually large photos to review.",
        isVideo: false,
        sortsBySizeDescending: true,
        displayLimit: 100
    )

    static let screenRecordings = CleanupCategory(
        kind: .screenRecordings,
        title: "Screen recordings",
        systemImage: "record.circle",
        noun: "recording",
        blurb: "Screen recordings are large and easy to forget",
        emptyTitle: "No screen recordings",
        emptySubtitle: "We didn't find any screen recordings to clean up.",
        isVideo: true,
        sortsBySizeDescending: true,
        displayLimit: nil
    )

    static let blurry = CleanupCategory(
        kind: .blurry,
        title: "Possibly blurry",
        systemImage: "camera.metering.none",
        noun: "photo",
        blurb: "Standalone shots that look soft — review before deleting",
        emptyTitle: "Nothing looks blurry",
        emptySubtitle: "We didn't flag any standalone photos as soft.",
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil
    )
}
