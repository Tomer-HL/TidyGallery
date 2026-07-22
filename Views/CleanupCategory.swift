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
        case food
        case pets
        case documents
        case nature
        case selfies
        case recommended
        case exactDuplicates
    }

    let kind: Kind
    var id: Kind { kind }

    /// Navigation title, e.g. "Large videos".
    let title: String
    /// Row/tab SF Symbol.
    let systemImage: String
    /// What this category counts, and how those counts pluralize. A typed
    /// case rather than a `String`, because a bare noun cannot be
    /// pluralized correctly outside English — see `ItemNoun`.
    let noun: ItemNoun
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
    /// Optional minimum on-disk size (bytes) an item must reach to be shown once
    /// sizes are measured. Keeps "Big files" from listing every ordinary photo.
    /// `nil` = no size floor.
    let minDisplayBytes: Int64?

    // MARK: Presets

    static let screenshots = CleanupCategory(
        kind: .screenshots,
        title: String(localized: "Screenshots"),
        systemImage: "camera.viewfinder",
        noun: .screenshot,
        blurb: String(localized: "Screen grabs you probably don't need anymore"),
        emptyTitle: String(localized: "No screenshots"),
        emptySubtitle: String(localized: "You don't have any screenshots to clean up right now."),
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let largeVideos = CleanupCategory(
        kind: .largeVideos,
        title: String(localized: "Large videos"),
        systemImage: "film.stack",
        noun: .video,
        blurb: String(localized: "Videos take the most space — biggest first"),
        emptyTitle: String(localized: "No videos"),
        emptySubtitle: String(localized: "There are no videos in your library to review."),
        isVideo: true,
        sortsBySizeDescending: true,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let bigFiles = CleanupCategory(
        kind: .bigFiles,
        title: String(localized: "Big files"),
        systemImage: "internaldrive",
        noun: .photo,
        blurb: String(localized: "Your largest photos and Live Photos"),
        emptyTitle: String(localized: "Nothing oversized"),
        emptySubtitle: String(localized: "We didn't find unusually large photos to review."),
        isVideo: false,
        sortsBySizeDescending: true,
        displayLimit: nil,          // the coordinator already floors, sorts, and caps
        minDisplayBytes: nil
    )

    static let screenRecordings = CleanupCategory(
        kind: .screenRecordings,
        title: String(localized: "Screen recordings"),
        systemImage: "record.circle",
        noun: .recording,
        blurb: String(localized: "Screen recordings are large and easy to forget"),
        emptyTitle: String(localized: "No screen recordings"),
        emptySubtitle: String(localized: "We didn't find any screen recordings to clean up."),
        isVideo: true,
        sortsBySizeDescending: true,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let blurry = CleanupCategory(
        kind: .blurry,
        title: String(localized: "Possibly blurry"),
        systemImage: "camera.metering.none",
        noun: .photo,
        blurb: String(localized: "Standalone shots that look soft — review before deleting"),
        emptyTitle: String(localized: "Nothing looks blurry"),
        emptySubtitle: String(localized: "We didn't flag any standalone photos as soft."),
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let food = CleanupCategory(
        kind: .food,
        title: String(localized: "Food"),
        systemImage: "fork.knife",
        noun: .foodPhoto,
        blurb: String(localized: "Meals and food shots detected on-device"),
        emptyTitle: String(localized: "No food photos"),
        emptySubtitle: String(localized: "We didn't detect any food photos to review."),
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let pets = CleanupCategory(
        kind: .pets,
        title: String(localized: "Pets"),
        systemImage: "pawprint",
        noun: .petPhoto,
        blurb: String(localized: "Photos of cats, dogs, and other pets"),
        emptyTitle: String(localized: "No pet photos"),
        emptySubtitle: String(localized: "We didn't detect any pet photos to review."),
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let documents = CleanupCategory(
        kind: .documents,
        title: String(localized: "Documents"),
        systemImage: "doc.text",
        noun: .document,
        blurb: String(localized: "Receipts, notes, and other document snaps"),
        emptyTitle: String(localized: "No documents"),
        emptySubtitle: String(localized: "We didn't detect any document photos to review."),
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let nature = CleanupCategory(
        kind: .nature,
        title: String(localized: "Nature & scenery"),
        systemImage: "mountain.2",
        noun: .photo,
        blurb: String(localized: "Landscapes, sunsets, and scenery detected on-device"),
        emptyTitle: String(localized: "No scenery photos"),
        emptySubtitle: String(localized: "We didn't detect any nature or scenery photos to review."),
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let selfies = CleanupCategory(
        kind: .selfies,
        title: String(localized: "Selfies"),
        systemImage: "person.crop.square",
        noun: .selfie,
        blurb: String(localized: "Front-camera shots, from your Selfies album"),
        emptyTitle: String(localized: "No selfies"),
        emptySubtitle: String(localized: "We didn't detect any selfies to review."),
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let exactDuplicates = CleanupCategory(
        kind: .exactDuplicates,
        title: String(localized: "Exact duplicates"),
        systemImage: "doc.on.doc",
        noun: .copy,
        blurb: String(localized: "Identical copies of the same image — one is always kept"),
        emptyTitle: String(localized: "No exact duplicates"),
        emptySubtitle: String(localized: "We didn't find any identical copies in your library."),
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let recommended = CleanupCategory(
        kind: .recommended,
        title: String(localized: "Recommended cleanup"),
        systemImage: "wand.and.stars",
        noun: .photo,
        blurb: String(localized: "The safe near-duplicates we suggest removing"),
        emptyTitle: String(localized: "Nothing to recommend"),
        emptySubtitle: String(localized: "There are no confident duplicate suggestions right now."),
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )
}
