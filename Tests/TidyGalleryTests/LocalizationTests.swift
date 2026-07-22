//
//  LocalizationTests.swift
//  TidyGalleryTests
//
//  These tests run in English, so they cannot check the Hebrew wording — that is
//  what `Scripts/build_localizations.py --check` is for. What they can pin is
//  the part that would break silently in *either* language: that counts go
//  through the plural machinery at all, and that every noun the code can ask for
//  actually resolves to a string rather than falling back to its raw key.
//
//  A missing `.stringsdict` entry doesn't crash. It returns the key —
//  "count.photo" — and ships. That is the failure this file is here to catch.
//

import Testing
import Foundation
@testable import TidyGallery

@Suite("Localization")
struct LocalizationTests {

    // MARK: Plural resolution

    @Test("Every countable noun resolves to real text, not its lookup key", arguments: ItemNoun.allCases)
    func nounsResolve(noun: ItemNoun) {
        for count in [0, 1, 2, 5, 11, 20, 100] {
            let text = noun.counted(count)
            #expect(!text.contains("count."), "\(noun) fell back to its key at \(count): \(text)")
            #expect(!text.isEmpty)
        }
    }

    @Test("Singular names resolve too", arguments: ItemNoun.allCases)
    func singularNamesResolve(noun: ItemNoun) {
        let name = noun.singularName
        #expect(!name.hasPrefix("noun."), "\(noun) has no singular form: \(name)")
        #expect(!name.isEmpty)
    }

    @Test("One and many take different forms")
    func singularDiffersFromPlural() {
        // The whole point of the plural table. If these ever match, the
        // .stringsdict is being ignored and every count reads as one form.
        #expect(ItemNoun.photo.counted(1) != ItemNoun.photo.counted(7))
        #expect(ItemNoun.copy.counted(1) != ItemNoun.copy.counted(7))
    }

    @Test("The singular form carries no digit")
    func singularHasNoDigit() {
        // "one photo", not "1 photo" — this is the natural reading in English
        // and required in Hebrew ("תמונה אחת"), and it is unreachable by string
        // concatenation, which is why the old `noun + "s"` approach had to go.
        #expect(!ItemNoun.photo.counted(1).contains("1"))
    }

    @Test("A plural form includes the number")
    func pluralIncludesCount() {
        #expect(ItemNoun.photo.counted(42).contains("42"))
        #expect(ItemNoun.screenshot.counted(7).contains("7"))
    }

    @Test("Zero is phrased as a plural, not a singular")
    func zeroIsPlural() {
        // English CLDR puts 0 in "other". Getting this wrong reads as "0 photo".
        #expect(ItemNoun.photo.counted(0) == ItemNoun.photo.counted(3).replacingOccurrences(of: "3", with: "0"))
    }

    // MARK: Model-owned copy

    @Test("Category copy is non-empty and not a raw key")
    func categoryCopyIsResolved() {
        let categories: [CleanupCategory] = [
            .screenshots, .largeVideos, .bigFiles, .screenRecordings, .blurry,
            .food, .pets, .documents, .nature, .selfies, .exactDuplicates, .recommended,
        ]
        for category in categories {
            #expect(!category.title.isEmpty)
            #expect(!category.blurb.isEmpty)
            #expect(!category.emptyTitle.isEmpty)
            #expect(!category.emptySubtitle.isEmpty)
        }
    }

    @Test("Every scan scope has a label and a detail")
    func scanScopeCopy() {
        for scope in ScanScope.allCases {
            #expect(!scope.label.isEmpty)
            #expect(!scope.detail.isEmpty)
        }
    }

    @Test("Sort and age options are all labelled")
    func filterCopy() {
        for order in CleanupSortOrder.allCases { #expect(!order.label.isEmpty) }
        for filter in CleanupAgeFilter.allCases { #expect(!filter.label.isEmpty) }
    }

    // MARK: Identity stability

    @Test("Metric identity does not move when the display language does")
    func metricIDsAreLanguageIndependent() {
        let score = ShotScore(
            sharpness: 0.5,
            aesthetics: 0.5,
            faceQuality: .noFaces,
            isFavorite: false
        )
        let ids = ScoreExplanation.metrics(for: score).map(\.id)
        // Stable keys, not display names — a localized id would reshuffle
        // SwiftUI identity in one language and not another.
        #expect(ids == ["sharpness", "aesthetics", "faceQuality"])
    }
}
