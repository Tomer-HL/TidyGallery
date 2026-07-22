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
        #expect(abs((metrics.measuredConcurrencyFactor ?? 0) - 4) < 0.01)
    }

    // MARK: The projection guard
    //
    // Two real device runs, same build, no Vision changes between them. The
    // projection swung from 22 minutes to 97 purely on sample size. These pin
    // both, so the guard can't silently regress into confident nonsense again.

    /// The trustworthy run: 56 fresh photos, 942 ms image load, 12.0 s Vision,
    /// 3.7 s wall clock.
    private func healthySampleRun() -> ScanMetrics {
        var metrics = ScanMetrics()
        let start = Date()
        metrics.startedAt = start
        metrics.finishedAt = start.addingTimeInterval(3.7)
        metrics.cacheHits = 156
        metrics.analysedFresh = 56
        metrics.record(ScanMetrics.Phase.imageLoad, seconds: 0.942, count: 56)
        metrics.record(ScanMetrics.Phase.vision, seconds: 12.0, count: 56)
        return metrics
    }

    /// The misleading run: only 4 fresh photos, 261 ms image load, 2.0 s Vision,
    /// 1.2 s wall clock. Same device, same code.
    private func tinySampleRun() -> ScanMetrics {
        var metrics = ScanMetrics()
        let start = Date()
        metrics.startedAt = start
        metrics.finishedAt = start.addingTimeInterval(1.2)
        metrics.cacheHits = 208
        metrics.analysedFresh = 4
        metrics.record(ScanMetrics.Phase.imageLoad, seconds: 0.261, count: 4)
        metrics.record(ScanMetrics.Phase.vision, seconds: 2.0, count: 4)
        return metrics
    }

    @Test("A four-photo sample produces no projection at all")
    func tinySampleIsNotProjected() {
        let metrics = tinySampleRun()

        #expect(!metrics.hasEnoughSamplesToProject)
        #expect(metrics.projectedSeconds(forFreshPhotos: 20_000) == nil)
        // The per-photo cost is still reported — it's a measurement. Only the
        // extrapolation is withheld.
        #expect(metrics.millisecondsPerFreshPhoto != nil)
    }

    @Test("A 56-photo sample still projects, and near the figure the device gave")
    func healthySampleStillProjects() {
        let metrics = healthySampleRun()

        #expect(metrics.hasEnoughSamplesToProject)
        let projected = metrics.projectedSeconds(forFreshPhotos: 20_000)
        #expect(projected != nil)
        // The device reported 21m56s; allow a minute of arithmetic drift.
        #expect(abs((projected ?? 0) - 1_316) < 60)
    }

    @Test("The concurrency factor is what collapsed, and it is now visible")
    func concurrencyFactorExplainsTheSwing() {
        // 4 photos can't fill a 4-wide pool; 56 nearly can. Surfacing this is
        // what lets a reader tell a small sample from a slow device — the two
        // are indistinguishable from the projection alone.
        let tiny = tinySampleRun().measuredConcurrencyFactor ?? 0
        let healthy = healthySampleRun().measuredConcurrencyFactor ?? 0

        #expect(tiny < 2.0)
        #expect(healthy > 3.0)
        #expect(healthy > tiny)
    }

    @Test("The report explains a withheld projection instead of leaving a hole")
    func reportExplainsWithheldProjection() {
        let report = tinySampleRun().report()

        #expect(!report.contains("Projected for 20,000 uncached photos:"))
        #expect(report.contains("too few to extrapolate"))
        #expect(report.contains("concurrency achieved"))
    }

    @Test("A still-running scan of a big library is 'not yet', not 'too few'")
    func liveScanIsNotBlamedOnSampleSize() {
        // The bug this replaced: `projectedSeconds` returns nil for THREE
        // reasons, and the fallback text assumed only one of them. Mid-scan
        // there is no `finishedAt`, so a run that had already analysed 5,000
        // photos was told it had "too few to extrapolate from (needs 25)".
        var metrics = ScanMetrics()
        metrics.startedAt = Date()          // no finishedAt — still scanning
        metrics.analysedFresh = 5_000
        metrics.record(ScanMetrics.Phase.imageLoad, seconds: 40, count: 5_000)
        metrics.record(ScanMetrics.Phase.vision, seconds: 60, count: 5_000)

        #expect(metrics.projection(forFreshPhotos: 20_000) == .notYet)
        #expect(metrics.hasEnoughSamplesToProject)   // the sample is fine

        let report = metrics.report()
        #expect(!report.contains("too few to extrapolate"))
        #expect(report.contains("still running"))
    }

    @Test("Nothing analysed fresh yet is also 'not yet'")
    func fullyCachedScanIsNotYet() {
        var metrics = ScanMetrics()
        let start = Date()
        metrics.startedAt = start
        metrics.finishedAt = start.addingTimeInterval(1.3)
        metrics.cacheHits = 199
        metrics.analysedFresh = 0

        #expect(metrics.projection(forFreshPhotos: 20_000) == .notYet)
        // A 100%-cached scan is a success, not a measurement failure — it must
        // not be nagged about sample size.
        #expect(!metrics.report().contains("too few to extrapolate"))
    }

    @Test("The reasoned projection and the plain optional agree")
    func projectionAndOptionalAgree() {
        let healthy = healthySampleRun()
        let tiny = tinySampleRun()

        #expect(healthy.projectedSeconds(forFreshPhotos: 20_000) != nil)
        if case .available = healthy.projection(forFreshPhotos: 20_000) {} else {
            Issue.record("healthy run should project")
        }
        #expect(tiny.projectedSeconds(forFreshPhotos: 20_000) == nil)
        #expect(tiny.projection(forFreshPhotos: 20_000) == .tooFewSamples(fresh: 4, needed: 25))
    }

    @Test("Right at the threshold the projection appears")
    func projectionThresholdBoundary() {
        var metrics = healthySampleRun()

        metrics.analysedFresh = ScanMetrics.minimumSampleForProjection - 1
        #expect(metrics.projectedSeconds(forFreshPhotos: 20_000) == nil)

        metrics.analysedFresh = ScanMetrics.minimumSampleForProjection
        #expect(metrics.projectedSeconds(forFreshPhotos: 20_000) != nil)
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

    // MARK: Per-asset cost

    @Test("Assets seen accumulate alongside time, so per-asset cost is right")
    func assetsSeenAccumulate() {
        var metrics = ScanMetrics()
        metrics.record(ScanMetrics.Phase.videoFetch, seconds: 0.5, assetsSeen: 50)
        metrics.record(ScanMetrics.Phase.videoFetch, seconds: 0.5, assetsSeen: 50)

        let phase = metrics.phases[0]
        #expect(phase.assetsSeen == 100)
        #expect(abs((phase.millisecondsPerAsset ?? 0) - 10.0) < 0.0001)
    }

    @Test("A phase that counts no assets reports no per-asset cost")
    func perAssetCostNeedsAssets() {
        var metrics = ScanMetrics()
        // Clustering works on already-loaded snapshots — "per asset" is
        // meaningless for it, and reporting 0.0 would read as "free".
        metrics.record(ScanMetrics.Phase.clustering, seconds: 0.5)

        #expect(metrics.phases[0].assetsSeen == 0)
        #expect(metrics.phases[0].millisecondsPerAsset == nil)
    }

    @Test("A tiny asset sample reports no per-asset rate — it can't tell fixed from marginal")
    func perAssetCostNeedsEnoughAssets() {
        var metrics = ScanMetrics()
        // The real numbers: opening the Screenshots smart album cost 107 ms and
        // found 2 photos. Divided out that reads "53 ms each", which would
        // project 20,000 screenshots at 18 minutes. It is actually ~100 ms of
        // fixed query cost that does not scale at all.
        metrics.record(ScanMetrics.Phase.screenshotFetch, seconds: 0.107, assetsSeen: 2)

        let phase = metrics.phases[0]
        #expect(phase.assetsSeen == 2)
        #expect(phase.millisecondsPerAsset == nil)
        // The total must still be visible — a cheap-looking rate is the danger,
        // not the phase itself.
        #expect(abs(phase.totalSeconds - 0.107) < 0.0001)
    }

    @Test("A large enough sample does report a per-asset rate")
    func perAssetCostAppearsAtScale() {
        var metrics = ScanMetrics()
        // Same run, the phase that genuinely does scale: 212 assets in 99 ms.
        metrics.record(ScanMetrics.Phase.bigFileCandidates, seconds: 0.099, assetsSeen: 212)

        #expect(abs((metrics.phases[0].millisecondsPerAsset ?? 0) - 0.467) < 0.001)
    }

    @Test("The threshold is what separates those two readings")
    func perAssetThresholdBoundary() {
        let below = PhaseTiming(
            name: "x", totalSeconds: 1,
            count: 1, assetsSeen: PhaseTiming.minimumAssetsForPerAssetCost - 1
        )
        let at = PhaseTiming(
            name: "x", totalSeconds: 1,
            count: 1, assetsSeen: PhaseTiming.minimumAssetsForPerAssetCost
        )
        #expect(below.millisecondsPerAsset == nil)
        #expect(at.millisecondsPerAsset != nil)
    }

    @Test("Per-asset cost is what distinguishes a slow call from a wide query")
    func perAssetCostSeparatesCauses() {
        var metrics = ScanMetrics()
        // Same duration, two very different problems: one call is expensive,
        // the other is cheap but walked twenty times as much of the library.
        metrics.record(ScanMetrics.Phase.recordingFilenameWalk, seconds: 1.0, assetsSeen: 100)
        metrics.record(ScanMetrics.Phase.bigFileCandidates, seconds: 1.0, assetsSeen: 2_000)

        #expect(abs((metrics.phases[0].millisecondsPerAsset ?? 0) - 10.0) < 0.0001)
        #expect(abs((metrics.phases[1].millisecondsPerAsset ?? 0) - 0.5) < 0.0001)
    }

    @Test("The report shows per-asset cost only for phases that count assets")
    func reportShowsPerAssetCost() {
        var metrics = ScanMetrics()
        metrics.record(ScanMetrics.Phase.videoFetch, seconds: 0.5, assetsSeen: 50)
        metrics.record(ScanMetrics.Phase.clustering, seconds: 0.5)

        let report = metrics.report()
        #expect(report.contains("50 assets"))
        #expect(report.contains("10.00 ms each"))
        // The clustering line must not gain a bogus "[0 assets, 0.00 ms each]".
        // Anchored on the opening bracket: a bare "0 assets" is a substring of
        // "50 assets" and would fail against the *correct* line above.
        #expect(!report.contains("[0 assets"))
    }

    @Test("A report from an older build still decodes, gaining defaults")
    func decodesOlderReport() throws {
        // Exactly what a pre-instrumentation build wrote: no assetsSeen on the
        // phase, no size counters on the metrics. This must load rather than
        // throw — losing it means losing the record of the scan that died.
        let legacy = """
        {
          "scopeLabel": "Entire library",
          "deviceSummary": "iPhone12,5",
          "scopedAssetCount": 212,
          "pagesProcessed": 2,
          "cacheHits": 156,
          "analysedFresh": 56,
          "iCloudSkipped": 0,
          "unavailable": 0,
          "analysisFailures": 0,
          "failureReasons": {},
          "phases": [{"name": "Vision analysis", "totalSeconds": 12.0, "count": 56}],
          "peakFootprintBytes": 55800000,
          "memorySamples": 7,
          "previousScanDidNotFinish": true
        }
        """

        let restored = try JSONDecoder().decode(ScanMetrics.self, from: Data(legacy.utf8))

        #expect(restored.scopedAssetCount == 212)
        #expect(restored.cacheHits == 156)
        #expect(restored.previousScanDidNotFinish)
        #expect(restored.phases.count == 1)
        #expect(restored.phases[0].assetsSeen == 0)       // defaulted, not thrown
        #expect(restored.phases[0].millisecondsPerAsset == nil)
        #expect(restored.sizesFromCache == 0)             // field didn't exist yet
        #expect(restored.sizeWalkSeconds == 0)
        #expect(restored.startedAt == nil)
    }

    @Test("Assets seen survive a round trip")
    func assetsSeenEncode() throws {
        var metrics = ScanMetrics()
        metrics.record(ScanMetrics.Phase.selfieFetch, seconds: 0.2, assetsSeen: 7)

        let restored = try JSONDecoder().decode(
            ScanMetrics.self,
            from: try JSONEncoder().encode(metrics)
        )
        #expect(restored.phases[0].assetsSeen == 7)
    }

    // MARK: On-disk size accounting

    @Test("Size cache hit rate is measured against lookups, not photos scanned")
    func sizeCacheHitRateDenominator() {
        var metrics = ScanMetrics()
        // Deliberately different from the analysis counters: a scan can measure
        // sizes for assets it never analysed (videos, screenshots), so sharing a
        // denominator would quietly report a rate for the wrong population.
        metrics.cacheHits = 100
        metrics.analysedFresh = 0
        metrics.sizesFromCache = 30
        metrics.sizesMeasured = 10

        #expect(abs((metrics.sizeCacheHitRate ?? 0) - 0.75) < 0.0001)
    }

    @Test("Size cache hit rate is nil when nothing was looked up")
    func sizeCacheHitRateNeedsData() {
        #expect(ScanMetrics().sizeCacheHitRate == nil)
    }

    @Test("Cost per measure divides by fresh measures only, never by cache hits")
    func costPerFreshSize() {
        var metrics = ScanMetrics()
        metrics.sizesFromCache = 900
        metrics.sizesMeasured = 100
        metrics.sizeWalkSeconds = 0.9

        // 900 ms over the 100 assets actually measured, not over all 1,000 —
        // otherwise caching would appear to make each measurement cheaper,
        // which is exactly the wrong conclusion.
        #expect(abs((metrics.millisecondsPerFreshSize ?? 0) - 9.0) < 0.0001)
    }

    @Test("Cost per measure ignores the pass total, which includes cache work")
    func costPerFreshSizeExcludesCacheOverhead() {
        var metrics = ScanMetrics()
        metrics.sizesFromCache = 19_997
        metrics.sizesMeasured = 3
        metrics.sizeWalkSeconds = 0.027           // 3 walks at ~9 ms
        // The pass as a whole took far longer — it still had to look up 20,000
        // cached entries. Billing that to 3 measures would report ~1,300 ms
        // each and make the cache look like a regression.
        metrics.record(ScanMetrics.Phase.sizeMeasurement, seconds: 4.0)

        #expect(abs((metrics.millisecondsPerFreshSize ?? 0) - 9.0) < 0.0001)
    }

    @Test("A fully cached scan reports no per-measure cost rather than zero")
    func costPerFreshSizeUndefinedWhenAllCached() {
        var metrics = ScanMetrics()
        metrics.sizesFromCache = 1_000
        metrics.sizesMeasured = 0
        metrics.record(ScanMetrics.Phase.sizeMeasurement, seconds: 0.01)

        #expect(metrics.millisecondsPerFreshSize == nil)
        #expect(metrics.sizeCacheHitRate == 1.0)
    }

    @Test("The report shows size accounting only once sizes were looked up")
    func reportIncludesSizeSection() {
        var metrics = ScanMetrics()
        #expect(!metrics.report().contains("ON-DISK SIZES"))

        metrics.sizesFromCache = 190
        metrics.sizesMeasured = 9
        let report = metrics.report()

        #expect(report.contains("ON-DISK SIZES"))
        #expect(report.contains("190"))
        #expect(report.contains("95%"))   // 190 / 199
    }

    @Test("Size counters survive a round trip through the metrics store")
    func sizeCountersEncode() throws {
        var metrics = ScanMetrics()
        metrics.sizesFromCache = 12
        metrics.sizesMeasured = 3
        metrics.sizeWalkSeconds = 0.027

        let restored = try JSONDecoder().decode(
            ScanMetrics.self,
            from: try JSONEncoder().encode(metrics)
        )
        #expect(restored.sizesFromCache == 12)
        #expect(restored.sizesMeasured == 3)
        #expect(abs(restored.sizeWalkSeconds - 0.027) < 0.0001)
    }
}
