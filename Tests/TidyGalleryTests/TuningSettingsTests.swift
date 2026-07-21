//
//  TuningSettingsTests.swift
//  TidyGalleryTests
//
//  The settings a user tunes on-device must survive app updates and must
//  correctly classify which changes force a re-scan.
//

import Testing
import Foundation
@testable import TidyGallery

@Suite("Tuning settings")
struct TuningSettingsTests {

    @Test("Settings overlay onto the full configuration")
    func appliedOntoConfiguration() {
        var settings = TuningSettings.default
        settings.duplicateSimilarity = 0.42
        settings.bigFileMinMB = 12

        let config = settings.applied()
        #expect(config.featurePrintSimilarityThreshold == 0.42)
        #expect(config.bigFileMinBytes == 12_000_000)
    }

    @Test("Unexposed configuration values keep their defaults")
    func leavesInternalKnobsAlone() {
        let config = TuningSettings.default.applied()
        #expect(config.burstTimeWindow == AnalysisConfiguration.default.burstTimeWindow)
        #expect(config.documentSimilarityThreshold == AnalysisConfiguration.default.documentSimilarityThreshold)
    }

    // MARK: Re-scan classification

    @Test("Derivation-time knobs do NOT force a re-scan")
    func derivationKnobsApplyInstantly() {
        var changed = TuningSettings.default
        changed.duplicateSimilarity = 0.25
        changed.blurryPercentile = 0.3
        changed.bigFileMinMB = 20

        #expect(!changed.requiresReanalysis(comparedTo: .default))
    }

    @Test("Analysis-time knobs DO force a re-scan")
    func analysisKnobsRequireRescan() {
        var confidence = TuningSettings.default
        confidence.sceneConfidence = 0.2
        #expect(confidence.requiresReanalysis(comparedTo: .default))

        var selfie = TuningSettings.default
        selfie.selfieFaceArea = 0.25
        #expect(selfie.requiresReanalysis(comparedTo: .default))
    }

    @Test("No change means no re-scan")
    func noChangeNoRescan() {
        #expect(!TuningSettings.default.requiresReanalysis(comparedTo: .default))
    }

    // MARK: Persistence

    @Test("Settings round-trip through Codable")
    func roundTrips() throws {
        var settings = TuningSettings.default
        settings.selfieFaceArea = 0.17
        settings.sceneConfidence = 0.09

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TuningSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("Missing keys fall back to defaults instead of failing")
    func tolerantDecoding() throws {
        // Simulates a blob saved before a knob existed: adding a setting must
        // never wipe the user's other choices.
        let partial = #"{"duplicateSimilarity": 0.3}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TuningSettings.self, from: partial)

        #expect(decoded.duplicateSimilarity == 0.3)
        #expect(decoded.blurryPercentile == TuningSettings.default.blurryPercentile)
        #expect(decoded.selfieFaceArea == TuningSettings.default.selfieFaceArea)
    }

    @Test("An empty object decodes to all defaults")
    func emptyObjectDecodes() throws {
        let decoded = try JSONDecoder().decode(TuningSettings.self, from: #"{}"#.data(using: .utf8)!)
        #expect(decoded == .default)
    }
}

@Suite("Age filtering")
struct CleanupAgeFilterTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(yearsAgo years: Double) -> Date {
        now.addingTimeInterval(-years * 365.25 * 24 * 60 * 60)
    }

    @Test("Any age accepts everything, including undated photos")
    func allAcceptsEverything() {
        #expect(CleanupAgeFilter.all.matches(date(yearsAgo: 10), now: now))
        #expect(CleanupAgeFilter.all.matches(nil, now: now))
    }

    @Test("Each bucket matches only its own range")
    func bucketsAreExclusive() {
        let recent = date(yearsAgo: 0.5)
        let middle = date(yearsAgo: 2)
        let old = date(yearsAgo: 5)

        #expect(CleanupAgeFilter.pastYear.matches(recent, now: now))
        #expect(!CleanupAgeFilter.pastYear.matches(middle, now: now))

        #expect(CleanupAgeFilter.oneToThreeYears.matches(middle, now: now))
        #expect(!CleanupAgeFilter.oneToThreeYears.matches(recent, now: now))
        #expect(!CleanupAgeFilter.oneToThreeYears.matches(old, now: now))

        #expect(CleanupAgeFilter.olderThanThreeYears.matches(old, now: now))
        #expect(!CleanupAgeFilter.olderThanThreeYears.matches(middle, now: now))
    }

    @Test("Undated photos are excluded by every specific filter")
    func undatedExcludedFromSpecificFilters() {
        for filter in CleanupAgeFilter.allCases where filter != .all {
            #expect(!filter.matches(nil, now: now))
        }
    }
}
