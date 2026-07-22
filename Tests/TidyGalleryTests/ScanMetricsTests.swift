//
//  ScanMetricsTests.swift
//  TidyGalleryTests
//
//  The point of instrumentation is to be trusted. A measurement that quietly
//  double-counts, or divides by the wrong denominator, is worse than no
//  measurement — it produces a confident wrong conclusion about whether the app
//  survives a 20,000-photo library.
//
//  `ScanMetrics` is a pure value type precisely so this can be pinned without a
//  photo library, a device, or Vision.
//

import Testing
import Foundation
@testable import TidyGallery

@Suite("Scan metrics")
struct ScanMetricsTests {

    // MARK: Phase accumulation

    @Test("Repeated phases accumulate rather than duplicating")
    func phasesAccumulate() {
        var metrics = ScanMetrics()
        metrics.record(ScanMetrics.Phase.vision, seconds: 0.2)
        metrics.record(ScanMetrics.Phase.vision, seconds: 0.3)

        #expect(metrics.phases.count == 1)
        #expect(abs(metrics.phases[0].totalSeconds - 0.5) < 0.0001)
        #expect(metrics.phases[0].count == 2)
    }

    @Test("Phases stay in the order they were first seen")
    func phaseOrderIsStable() {
        var metrics = ScanMetrics()
        metrics.record(ScanMetrics.Phase.cacheLookup, seconds: 0.1)
        metrics.record(ScanMetrics.Phase.imageLoad, seconds: 0.1)
        metrics.record(ScanMetrics.Phase.cacheLookup, seconds: 0.1)
        metrics.record(ScanMetrics.Phase.vision, seconds: 0.1)

        #expect(metrics.phases.map(\.name) == [
            ScanMetrics.Phase.cacheLookup,
            ScanMetrics.Phase.imageLoad,
            ScanMetrics.Phase.vision,
        ])
    }

    @Test("Nonsense durations are ignored, not recorded")
    func rejectsInvalidDurations() {
        var metrics = ScanMetrics()
        metrics.record(ScanMetrics.Phase.vision, seconds: -1)
        metrics.record(ScanMetrics.Phase.vision, seconds: .nan)
        metrics.record(ScanMetrics.Phase.vision, seconds: .infinity)

        #expect(metrics.phases.isEmpty)
    }

    @Test("Average is per occurrence, not per second")
    func averagePerOccurrence() {
        var metrics = ScanMetrics()
        metrics.record(ScanMetrics.Phase.imageLoad, seconds: 1.0)
        metrics.record(ScanMetrics.Phase.imageLoad, seconds: 3.0)

        #expect(abs(metrics.phases[0].averageMilliseconds - 2000) < 0.01)
    }

    // MARK: Memory

    @Test("Memory sampling keeps the worst case in each direction")
    func memoryKeepsExtremes() {
        var metrics = ScanMetrics()
        metrics.sampleMemory(footprintBytes: 100, availableBytes: 900)
        metrics.sampleMemory(footprintBytes: 400, availableBytes: 300)
        metrics.sampleMemory(footprintBytes: 250, availableBytes: 700)

        #expect(metrics.peakFootprintBytes == 400)   // highest footprint
        #expect(metrics.minAvailableBytes == 300)    // lowest headroom
        #expect(metrics.memorySamples == 3)
    }

    @Test("Headroom stays nil when the platform never reports it")
    func headroomAbsentIsNotZero() {
        var metrics = ScanMetrics()
        metrics.sampleMemory(footprintBytes: 100, availableBytes: nil)
        metrics.sampleMemory(footprintBytes: 200, availableBytes: nil)

        // Crucially NOT 0 — "unknown" and "no memory left" must never be
        // conflated, since the second would be a five-alarm finding.
        #expect(metrics.minAvailableBytes == nil)
        #expect(metrics.peakFootprintBytes == 200)
    }

    @Test("A first headroom reading is adopted even after nil readings")
    func headroomAdoptsFirstRealReading() {
        var metrics = ScanMetrics()
        metrics.sampleMemory(footprintBytes: 10, availableBytes: nil)
        metrics.sampleMemory(footprintBytes: 10, availableBytes: 5_000)

        #expect(metrics.minAvailableBytes == 5_000)
    }

    // MARK: Failures

    @Test("Failure reasons are counted per distinct message")
    func failuresGroupByReason() {
        var metrics = ScanMetrics()
        metrics.noteFailure("featurePrintUnavailable")
        metrics.noteFailure("featurePrintUnavailable")
        metrics.noteFailure("decodeFailed")

        #expect(metrics.analysisFailures == 3)
        #expect(metrics.failureReasons["featurePrintUnavailable"] == 2)
        #expect(metrics.failureReasons["decodeFailed"] == 1)
    }

    @Test("The reason map is bounded so a systematic failure can't blow it up")
    func failureReasonsAreBounded() {
        var metrics = ScanMetrics()
        // Simulates the pathological case: a unique message per photo (an id or
        // an address embedded in the error), thousands of times over.
        for i in 0..<500 {
            metrics.noteFailure("unique failure \(i)")
        }

        #expect(metrics.analysisFailures == 500)
        #expect(metrics.failureReasons.count <= 13)   // 12 distinct + "Other"
        #expect(metrics.failureReasons["Other"] == 488)
    }

    // MARK: Derived figures

    @Test("Processed count includes every outcome, not just successes")
    func processedCountsAllOutcomes() {
        var metrics = ScanMetrics()
        metrics.cacheHits = 10
        metrics.analysedFresh = 5
        metrics.iCloudSkipped = 3
        metrics.unavailable = 1
        metrics.noteFailure("boom")

        #expect(metrics.processedCount == 20)
    }

    @Test("Cache hit rate ignores photos that were never candidates")
    func cacheHitRateDenominator() {
        var metrics = ScanMetrics()
        metrics.cacheHits = 30
        metrics.analysedFresh = 10
        // iCloud skips never consulted the cache in a meaningful way, so
        // including them would understate the hit rate.
        metrics.iCloudSkipped = 1000

        #expect(abs((metrics.cacheHitRate ?? 0) - 0.75) < 0.0001)
    }

    @Test("Derived figures are nil rather than zero when undefined")
    func undefinedFiguresAreNil() {
        let empty = ScanMetrics()
        #expect(empty.cacheHitRate == nil)
        #expect(empty.photosPerSecond == nil)
        #expect(empty.millisecondsPerFreshPhoto == nil)
        #expect(empty.wallClockSeconds == nil)
        #expect(empty.projectedSeconds(forFreshPhotos: 20_000) == nil)
        #expect(empty.isEmpty)
    }

    @Test("Wall clock is nil when the finish timestamp precedes the start")
    func rejectsNegativeWallClock() {
        var metrics = ScanMetrics()
        let now = Date()
        metrics.startedAt = now
        metrics.finishedAt = now.addingTimeInterval(-10)

        #expect(metrics.wallClockSeconds == nil)
    }

    @Test("Per-photo cost sums load and Vision across the whole scan")
    func perFreshPhotoCost() {
        var metrics = ScanMetrics()
        metrics.analysedFresh = 100
        metrics.record(ScanMetrics.Phase.imageLoad, seconds: 4.0, count: 100)
        metrics.record(ScanMetrics.Phase.vision, seconds: 6.0, count: 100)

        // 10 s of serial work over 100 photos = 100 ms each.
        #expect(abs((metrics.millisecondsPerFreshPhoto ?? 0) - 100) < 0.01)
    }

    @Test("Projection accounts for the concurrency actually achieved")
    func projectionUsesMeasuredConcurrency() {
        var metrics = ScanMetrics()
        let start = Date()
        metrics.startedAt = start
        metrics.finishedAt = start.addingTimeInterval(25)   // 25 s wall clock
        metrics.analysedFresh = 1000
        // 100 s of serial work done in 25 s → an effective concurrency of 4.
        metrics.record(ScanMetrics.Phase.imageLoad, seconds: 40, count: 1000)
        metrics.record(ScanMetrics.Phase.vision, seconds: 60, count: 1000)

        // 20,000 photos at the same serial cost (100 ms) and the same 4x
        // concurrency = 2000 s / 4 = 500 s.
        let projected = metrics.projectedSeconds(forFreshPhotos: 20_000)
        #expect(projected != nil)
        #expect(abs((projected ?? 0) - 500) < 1)
    }

    // MARK: Report

    @Test("The report includes the figures a reader needs to act on")
    func reportContainsKeyFigures() {
        var metrics = ScanMetrics()
        metrics.scopeLabel = "Entire library"
        metrics.deviceSummary = "iPhone16,1 · iOS 18.5"
        metrics.startedAt = Date()
        metrics.finishedAt = metrics.startedAt?.addingTimeInterval(60)
        metrics.scopedAssetCount = 20_000
        metrics.analysedFresh = 20_000
        metrics.sampleMemory(footprintBytes: 350_000_000, availableBytes: 900_000_000)
        metrics.record(ScanMetrics.Phase.vision, seconds: 120, count: 20_000)

        let report = metrics.report()
        #expect(report.contains("iPhone16,1"))
        #expect(report.contains("Entire library"))
        #expect(report.contains("20000"))
        #expect(report.contains("MEMORY"))
        #expect(report.contains(ScanMetrics.Phase.vision))
    }

    @Test("An interrupted previous scan is called out prominently")
    func reportWarnsAboutInterruptedScan() {
        var metrics = ScanMetrics()
        metrics.previousScanDidNotFinish = true
        metrics.startedAt = Date()

        let report = metrics.report()
        #expect(report.contains("WARNING"))
        #expect(report.uppercased().contains("MEMORY"))
    }

    @Test("A report can be produced before a scan finishes")
    func reportSurvivesIncompleteScan() {
        var metrics = ScanMetrics()
        metrics.startedAt = Date()
        metrics.cacheHits = 5

        // No crash, no nonsense duration — the screen renders live during a scan.
        #expect(metrics.report().contains("still running"))
    }

    // MARK: Round-tripping

    @Test("Metrics survive being persisted and reloaded")
    func codableRoundTrip() throws {
        var metrics = ScanMetrics()
        metrics.scopeLabel = "Past year"
        metrics.analysedFresh = 42
        metrics.record(ScanMetrics.Phase.imageLoad, seconds: 1.5, count: 42)
        metrics.sampleMemory(footprintBytes: 123, availableBytes: 456)
        metrics.noteFailure("boom")

        let data = try JSONEncoder().encode(metrics)
        let restored = try JSONDecoder().decode(ScanMetrics.self, from: data)

        #expect(restored == metrics)
        #expect(restored.phases.count == 1)
        #expect(restored.failureReasons["boom"] == 1)
    }

    // MARK: Duration conversion

    @Test("Duration converts to seconds without losing sub-second precision")
    func durationInSeconds() {
        #expect(abs(Duration.milliseconds(250).inSeconds - 0.25) < 0.000001)
        #expect(abs(Duration.seconds(3).inSeconds - 3.0) < 0.000001)
        #expect(Duration.zero.inSeconds == 0)
    }

    @Test("Durations format at a human scale")
    func durationFormatting() {
        #expect(ScanMetrics.duration(0.25).contains("ms"))
        #expect(ScanMetrics.duration(12).contains("s"))
        #expect(ScanMetrics.duration(125) == "2m 5s")
    }
}
