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
    /// Optional minimum on-disk size (bytes) an item must reach to be shown once
    /// sizes are measured. Keeps "Big files" from listing every ordinary photo.
    /// `nil` = no size floor.
    let minDisplayBytes: Int64?

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
        displayLimit: nil,
        minDisplayBytes: nil
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
        displayLimit: nil,
        minDisplayBytes: nil
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
        displayLimit: nil,          // the coordinator already floors, sorts, and caps
        minDisplayBytes: nil
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
        displayLimit: nil,
        minDisplayBytes: nil
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
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let food = CleanupCategory(
        kind: .food,
        title: "Food",
        systemImage: "fork.knife",
        noun: "food photo",
        blurb: "Meals and food shots detected on-device",
        emptyTitle: "No food photos",
        emptySubtitle: "We didn't detect any food photos to review.",
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let pets = CleanupCategory(
        kind: .pets,
        title: "Pets",
        systemImage: "pawprint",
        noun: "pet photo",
        blurb: "Photos of cats, dogs, and other pets",
        emptyTitle: "No pet photos",
        emptySubtitle: "We didn't detect any pet photos to review.",
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let documents = CleanupCategory(
        kind: .documents,
        title: "Documents",
        systemImage: "doc.text",
        noun: "document",
        blurb: "Receipts, notes, and other document snaps",
        emptyTitle: "No documents",
        emptySubtitle: "We didn't detect any document photos to review.",
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let nature = CleanupCategory(
        kind: .nature,
        title: "Nature & scenery",
        systemImage: "mountain.2",
        noun: "photo",
        blurb: "Landscapes, sunsets, and scenery detected on-device",
        emptyTitle: "No scenery photos",
        emptySubtitle: "We didn't detect any nature or scenery photos to review.",
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let selfies = CleanupCategory(
        kind: .selfies,
        title: "Selfies",
        systemImage: "person.crop.square",
        noun: "selfie",
        blurb: "Close-up portraits, detected from face size",
        emptyTitle: "No selfies",
        emptySubtitle: "We didn't detect any selfies to review.",
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let exactDuplicates = CleanupCategory(
        kind: .exactDuplicates,
        title: "Exact duplicates",
        systemImage: "doc.on.doc",
        noun: "copy",
        blurb: "Identical copies of the same image — one is always kept",
        emptyTitle: "No exact duplicates",
        emptySubtitle: "We didn't find any identical copies in your library.",
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )

    static let recommended = CleanupCategory(
        kind: .recommended,
        title: "Recommended cleanup",
        systemImage: "wand.and.stars",
        noun: "photo",
        blurb: "The safe near-duplicates we suggest removing",
        emptyTitle: "Nothing to recommend",
        emptySubtitle: "There are no confident duplicate suggestions right now.",
        isVideo: false,
        sortsBySizeDescending: false,
        displayLimit: nil,
        minDisplayBytes: nil
    )
}
