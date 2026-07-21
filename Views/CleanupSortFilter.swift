//
//  CleanupSortFilter.swift
//  TidyGallery
//
//  Sort and age-filter options for a cleanup grid.
//
//  Note on "search": photos carry no text to match, so a free-text field would
//  have nothing useful to search. The equivalent that actually helps when
//  cleaning up is filtering by AGE — "screenshots older than a year" is the real
//  question people ask — so that's what `AgeFilter` provides.
//

import Foundation

/// How a cleanup grid is ordered.
enum CleanupSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newest
    case oldest
    case largest
    case smallest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .largest: "Largest first"
        case .smallest: "Smallest first"
        }
    }

    var systemImage: String {
        switch self {
        case .newest, .oldest: "calendar"
        case .largest, .smallest: "internaldrive"
        }
    }

    /// Whether this order needs measured file sizes to be meaningful.
    var needsSizes: Bool {
        self == .largest || self == .smallest
    }
}

/// Restricts a cleanup grid to a slice of the user's timeline.
enum CleanupAgeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case pastYear
    case oneToThreeYears
    case olderThanThreeYears

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "Any age"
        case .pastYear: "Past year"
        case .oneToThreeYears: "1–3 years old"
        case .olderThanThreeYears: "Older than 3 years"
        }
    }

    /// Whether a photo created on `date` belongs in this slice. Undated photos
    /// are only shown under "Any age" so they're never silently hidden by a
    /// filter they can't be evaluated against.
    func matches(_ date: Date?, now: Date = .now) -> Bool {
        guard self != .all else { return true }
        guard let date else { return false }
        let years = now.timeIntervalSince(date) / (365.25 * 24 * 60 * 60)
        switch self {
        case .all: return true
        case .pastYear: return years < 1
        case .oneToThreeYears: return years >= 1 && years < 3
        case .olderThanThreeYears: return years >= 3
        }
    }
}
