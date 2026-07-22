//
//  ScanMetrics.swift
//  TidyGallery
//
//  Instrumentation for the scan pipeline: where the time goes, how much memory
//  the process is holding, and what the analyser couldn't handle.
//
//  Why this exists
//  ---------------
//  The whole memory design of this app — paged fetches, snapshot value types,
//  bounded analysis concurrency, ~512px thumbnails — is a set of *claims* about
//  behaviour on a 20,000-photo library. None of them had ever been measured on a
//  real device. This type is how they get measured: a pure, `Sendable`,
//  `Codable` value that the coordinator fills in as it works and the Diagnostics
//  screen prints.
//
//  It is deliberately a plain value type with no dependency on Photos, Vision,
//  UIKit or SwiftData, so the aggregation and formatting logic can be unit
//  tested without mocking any of them.
//
//  Cost: negligible. A handful of integer increments per photo, one `task_info`
//  call per page, and no allocation in the hot path.
//

import Foundation

extension Duration {
    /// This duration as seconds. `Duration` deliberately has no lossy
    /// conversion, but every timing here is a human-scale measurement destined
    /// for a report, so the precision loss is irrelevant.
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

/// Accumulated wall-clock time spent in one named stage of the pipeline.
struct PhaseTiming: Sendable, Equatable, Codable, Identifiable {
    let name: String
    /// Total seconds spent in this phase across the whole scan.
    var totalSeconds: Double
    /// How many times the phase ran (pages, photos, passes — phase dependent).
    var count: Int

    /// How many assets this phase walked, where that is meaningful.
    ///
    /// Duration alone can't tell "slow per asset" apart from "walked far more
    /// assets than expected", and those have opposite fixes: the first wants a
    /// cheaper per-asset call, the second wants a narrower query. Zero means
    /// the phase doesn't count assets, not that it saw none.
    var assetsSeen: Int = 0

    var id: String { name }

    var averageMilliseconds: Double {
        count > 0 ? (totalSeconds / Double(count)) * 1000 : 0
    }

    /// Fewest assets a phase must have walked before its per-asset cost is
    /// reported.
    ///
    /// Below this, the figure cannot separate fixed cost from marginal cost,
    /// and it is the marginal one that extrapolates. A device run made this
    /// concrete:
    ///
    ///   Screenshots  107 ms over   2 assets → "53.38 ms each"
    ///   Selfies      111 ms over  36 assets → "3.08 ms each"
    ///   Big files     99 ms over 212 assets → "0.47 ms each"
    ///
    /// Read as a scaling rate, the first says 20,000 screenshots would take 18
    /// minutes. In fact all three are the same ~100 ms fixed cost of opening a
    /// smart album, and only the last has enough assets for the per-asset term
    /// to dominate the constant. Showing nothing is better than showing a
    /// number whose only honest reading requires already knowing this.
    ///
    /// The phase's total is always printed, so a small-sample phase that is
    /// nonetheless expensive stays visible.
    static let minimumAssetsForPerAssetCost = 30

    /// Cost per asset walked — the figure that extrapolates to a big library.
    /// `nil` when too few assets were walked to tell fixed from marginal cost.
    var millisecondsPerAsset: Double? {
        guard assetsSeen >= Self.minimumAssetsForPerAssetCost else { return nil }
        return (totalSeconds / Double(assetsSeen)) * 1000
    }

    init(name: String, totalSeconds: Double, count: Int, assetsSeen: Int = 0) {
        self.name = name
        self.totalSeconds = totalSeconds
        self.count = count
        self.assetsSeen = assetsSeen
    }

    /// Hand-written so a report saved by an older build still decodes.
    ///
    /// Swift's synthesized `init(from:)` does **not** fall back to a property's
    /// default value for a missing key — it throws. `ScanMetricsStore.load()`
    /// swallows that with `try?`, so adding a field would silently discard the
    /// previous run's report. That is the wrong report to lose: the one worth
    /// reading is usually the scan that never finished, and the update that
    /// added the field is often the one you installed to investigate it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        totalSeconds = try container.decodeIfPresent(Double.self, forKey: .totalSeconds) ?? 0
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        assetsSeen = try container.decodeIfPresent(Int.self, forKey: .assetsSeen) ?? 0
    }
}

/// A single scan's measurements.
struct ScanMetrics: Sendable, Equatable, Codable {

    /// Canonical phase names, so the recorder and the tests agree on spelling.
    enum Phase {
        /// Metadata-only pass: screenshots, videos, recordings, big files.
        static let metadataPass = "Metadata pass"
        /// Batched SwiftData lookup of already-analysed photos.
        static let cacheLookup = "Cache lookup"
        /// Photos-framework image request (decode + downscale to ~512px).
        static let imageLoad = "Image load"
        /// Vision: feature print, faces, classification, aesthetics.
        static let vision = "Vision analysis"
        /// Batched SwiftData write of new results.
        static let cacheWrite = "Cache write"
        /// Time-gate + feature-print clustering into stacks.
        static let clustering = "Clustering"
        /// Re-deriving every published category list from the working set.
        static let derivation = "Category derivation"
        /// Off-main on-disk size measurement of the library.
        static let sizeMeasurement = "Size measurement"

        // MARK: Metadata pass, broken down
        //
        // The metadata pass is the cost paid on EVERY launch — unlike Vision,
        // which is per-photo-once. It did not improve when on-disk sizes were
        // cached, which falsified the assumption that `PHAssetResource`
        // dominated it. These sub-phases exist so the next attempt is aimed by
        // measurement rather than by another guess. The four fetches run
        // concurrently, so their sum legitimately exceeds the parent total.

        /// `fetchVideosAndScreenRecordings` end to end.
        static let videoFetch = "└ Videos + recordings"
        /// Just the per-video `PHAssetResource` walk that looks for the
        /// ReplayKit filename prefix — a resource lookup the size cache cannot
        /// serve, because it wants a filename rather than a size.
        static let recordingFilenameWalk = "  └ recording filename walk"
        /// The system Screenshots smart album.
        static let screenshotFetch = "└ Screenshots"
        /// The system Selfies smart album.
        static let selfieFetch = "└ Selfies"
        /// Enumerating every still to rank candidates by pixel area.
        static let bigFileCandidates = "└ Big-file candidates"
        /// Resolving on-disk sizes for that bounded candidate pool.
        static let bigFileSizes = "  └ Big-file sizes"
    }

    // MARK: Context

    /// Which scan scope produced these numbers ("Entire library", "Past year"…).
    var scopeLabel = ""
    /// e.g. "iPhone15,2 · iOS 18.5 · TidyGallery 1.0 (1)". Filled in by the UI
    /// layer, since this type must stay free of UIKit.
    var deviceSummary = ""
    var startedAt: Date?
    var finishedAt: Date?

    // MARK: Volume

    /// Total assets in the scoped fetch, reported by the first page.
    var scopedAssetCount = 0
    var pagesProcessed = 0

    /// Photos already analysed in a previous run (no image load, no Vision).
    var cacheHits = 0
    /// Photos analysed from scratch this run.
    var analysedFresh = 0
    /// Skipped because the full-quality original lives only in iCloud.
    var iCloudSkipped = 0
    /// The Photos framework returned no usable image.
    var unavailable = 0
    /// Vision threw. Counted rather than aborting the scan.
    var analysisFailures = 0
    /// Distinct failure messages and how often each occurred, so a systematic
    /// problem is distinguishable from one odd photo.
    var failureReasons: [String: Int] = [:]

    /// On-disk sizes served from `CachedAssetSize` without touching Photos.
    var sizesFromCache = 0
    /// On-disk sizes walked fresh via `PHAssetResource` — the ~9 ms/asset path.
    var sizesMeasured = 0
    /// Seconds spent in those walks alone. Deliberately NOT the `sizeMeasurement`
    /// phase total, which also covers cache lookups and writes for every asset
    /// in scope — dividing that by `sizesMeasured` would make the per-measure
    /// cost appear to blow up exactly when the cache is doing its job.
    var sizeWalkSeconds: Double = 0

    // MARK: Timing

    /// Ordered by first occurrence, so the report reads in pipeline order.
    private(set) var phases: [PhaseTiming] = []

    // MARK: Memory

    /// Highest process footprint observed during the scan, in bytes.
    var peakFootprintBytes: Int64 = 0
    /// Lowest headroom reported by `os_proc_available_memory()`. This is the
    /// number that actually predicts a jetsam kill — footprint alone doesn't,
    /// since the limit varies by device and by what else is running.
    var minAvailableBytes: Int64?
    var memorySamples = 0

    /// True when the previous scan started but never recorded a finish —
    /// the fingerprint of the app being killed mid-scan (OOM or a crash).
    var previousScanDidNotFinish = false

    /// How a run ended. Three outcomes that used to be two.
    ///
    /// "Didn't finish" was a single boolean, so a scan the user deliberately
    /// stopped was indistinguishable from one iOS killed for memory. On a
    /// twenty-minute pass over a large library that is not a rare edge case —
    /// abandoning a scan is the expected thing to do when the phone gets hot,
    /// and it would have poisoned the exact signal this instrumentation exists
    /// to produce.
    enum Outcome: String, Sendable, Codable {
        /// Ran to completion.
        case completed
        /// Written while work is still in progress. A report left in this state
        /// is what a jetsam kill looks like from the next launch.
        case inProgress
        /// The user stopped it. Not a failure, and not evidence of anything.
        case cancelled
        /// The scan threw. Distinct from a kill: the app was alive enough to
        /// record it, so it is a bug to fix rather than a memory limit to
        /// design around. Without this case a thrown scan was saved as
        /// `.completed`, quietly claiming success on the report.
        case failed
    }

    var outcome: Outcome = .inProgress

    /// Whether this report captures a run that never reached its end — either
    /// because it was killed, or because it is still going.
    var isPartial: Bool { outcome != .completed }

    // MARK: - Recording

    /// Adds time to a phase, creating it on first use and preserving the order
    /// phases were first seen in.
    mutating func record(_ name: String, seconds: Double, count: Int = 1, assetsSeen: Int = 0) {
        guard seconds.isFinite, seconds >= 0 else { return }
        if let index = phases.firstIndex(where: { $0.name == name }) {
            phases[index].totalSeconds += seconds
            phases[index].count += count
            phases[index].assetsSeen += assetsSeen
        } else {
            phases.append(
                PhaseTiming(name: name, totalSeconds: seconds, count: count, assetsSeen: assetsSeen)
            )
        }
    }

    /// Folds in a memory reading. Keeps the worst case in each direction.
    mutating func sampleMemory(footprintBytes: Int64, availableBytes: Int64?) {
        memorySamples += 1
        peakFootprintBytes = max(peakFootprintBytes, footprintBytes)
        if let available = availableBytes {
            minAvailableBytes = min(minAvailableBytes ?? available, available)
        }
    }

    /// Records one photo that Vision couldn't analyse.
    mutating func noteFailure(_ reason: String) {
        analysisFailures += 1
        // Bound the map: a systematic failure would otherwise write thousands of
        // near-identical keys. Twelve distinct causes is plenty to diagnose with.
        if failureReasons[reason] != nil || failureReasons.count < 12 {
            failureReasons[reason, default: 0] += 1
        } else {
            failureReasons["Other", default: 0] += 1
        }
    }

    // MARK: - Derived

    /// Photos the analysis pass reached, by any outcome.
    var processedCount: Int {
        cacheHits + analysedFresh + iCloudSkipped + unavailable + analysisFailures
    }

    var wallClockSeconds: Double? {
        guard let startedAt, let finishedAt else { return nil }
        let elapsed = finishedAt.timeIntervalSince(startedAt)
        return elapsed >= 0 ? elapsed : nil
    }

    /// Throughput over the whole scan, including cache hits.
    var photosPerSecond: Double? {
        guard let seconds = wallClockSeconds, seconds > 0, processedCount > 0 else { return nil }
        return Double(processedCount) / seconds
    }

    /// Cost per *freshly analysed* photo — the number that projects to a bigger
    /// library, since cache hits are nearly free.
    var millisecondsPerFreshPhoto: Double? {
        guard analysedFresh > 0 else { return nil }
        let load = phases.first { $0.name == Phase.imageLoad }?.totalSeconds ?? 0
        let vision = phases.first { $0.name == Phase.vision }?.totalSeconds ?? 0
        guard load + vision > 0 else { return nil }
        return ((load + vision) / Double(analysedFresh)) * 1000
    }

    var cacheHitRate: Double? {
        let considered = cacheHits + analysedFresh
        guard considered > 0 else { return nil }
        return Double(cacheHits) / Double(considered)
    }

    /// Share of size lookups answered without walking `PHAssetResource`.
    var sizeCacheHitRate: Double? {
        let considered = sizesFromCache + sizesMeasured
        guard considered > 0 else { return nil }
        return Double(sizesFromCache) / Double(considered)
    }

    /// Cost per *freshly measured* size. This is the number the size cache
    /// exists to stop paying: it stays roughly constant (~9 ms) while the count
    /// it multiplies should fall to near zero on every scan after the first.
    var millisecondsPerFreshSize: Double? {
        guard sizesMeasured > 0, sizeWalkSeconds > 0 else { return nil }
        return (sizeWalkSeconds / Double(sizesMeasured)) * 1000
    }

    /// Fewest freshly-analysed photos a run must have before its per-photo cost
    /// is allowed to be extrapolated.
    ///
    /// Not a round number picked for tidiness — it is the smallest sample that
    /// can plausibly saturate the analysis pool AND amortise Vision's one-time
    /// model load. Two device runs, same build, no Vision changes between them:
    ///
    ///   56 fresh photos → 231 ms each, concurrency 3.5× → projected 22 min
    ///    4 fresh photos → 565 ms each, concurrency 1.9× → projected 97 min
    ///
    /// Four photos cannot fill a four-wide pool, so the measured concurrency
    /// factor collapses toward 1; and the model warmup, negligible spread over
    /// 56 photos, is a quarter of the cost when spread over 4. Both errors push
    /// the same way, and the result was a confident 97-minute figure that was
    /// wrong by more than 4×. A projection that only appears when it means
    /// something is worth more than one that is always present.
    static let minimumSampleForProjection = 25

    /// How much parallelism the analysis pass actually achieved: serial cost
    /// divided by elapsed time.
    ///
    /// Surfaced rather than left implicit inside the projection, because when
    /// this collapses the projection inflates, and a reader who can't see it
    /// has no way to tell a slow device from a small sample.
    var measuredConcurrencyFactor: Double? {
        guard
            let perPhotoMs = millisecondsPerFreshPhoto,
            let seconds = wallClockSeconds,
            seconds > 0,
            analysedFresh > 0
        else { return nil }
        let serialSeconds = (perPhotoMs / 1000) * Double(analysedFresh)
        guard serialSeconds > 0 else { return nil }
        return serialSeconds / seconds
    }

    /// Whether this run analysed enough photos for `projectedSeconds` to mean
    /// anything. Exposed so the UI can explain the absence rather than just
    /// showing a gap.
    var hasEnoughSamplesToProject: Bool {
        analysedFresh >= Self.minimumSampleForProjection
    }

    /// Why a projection is or isn't available.
    ///
    /// A bare `Double?` forced every caller to re-derive the reason from the
    /// other properties, and they got it wrong in the same way: treating "no
    /// projection" as always meaning "too small a sample". It also means
    /// "hasn't finished yet", which during a live scan of a large library
    /// produced the self-contradicting "only 5000 fresh photos, too few to
    /// extrapolate from (needs 25)". One value, computed once, keeps the
    /// text report and the Diagnostics screen from disagreeing.
    enum Projection: Sendable, Equatable {
        /// Seconds, extrapolated at the concurrency actually achieved.
        case available(Double)
        /// The run is valid but too small to extrapolate from.
        case tooFewSamples(fresh: Int, needed: Int)
        /// Still scanning, or nothing analysed fresh yet — ask again later.
        case notYet
    }

    /// Projected wall clock for a library of `assetCount` photos, assuming none
    /// are cached. Rough by construction — it extrapolates the per-photo cost
    /// measured here — but it answers "will 20k photos take 4 minutes or 40?"
    func projection(forFreshPhotos assetCount: Int) -> Projection {
        guard analysedFresh > 0 else { return .notYet }
        guard hasEnoughSamplesToProject else {
            return .tooFewSamples(fresh: analysedFresh, needed: Self.minimumSampleForProjection)
        }
        // Missing timings or an unfinished scan — a real "not yet", distinct
        // from a sample that will never be big enough.
        guard
            let perPhotoMs = millisecondsPerFreshPhoto,
            let factor = measuredConcurrencyFactor,
            factor > 0
        else { return .notYet }
        // Analysis runs concurrently, so per-photo Vision+load time overstates
        // wall clock. Scale by the measured concurrency factor instead of
        // assuming the configured limit was actually achieved.
        return .available((perPhotoMs / 1000) * Double(assetCount) / factor)
    }

    /// The projection as a plain optional, for callers that only want the number.
    func projectedSeconds(forFreshPhotos assetCount: Int) -> Double? {
        guard case let .available(seconds) = projection(forFreshPhotos: assetCount) else {
            return nil
        }
        return seconds
    }

    /// Nothing has been recorded yet.
    var isEmpty: Bool { startedAt == nil && processedCount == 0 }
}

// MARK: - Forward-compatible decoding

extension ScanMetrics {

    // No `init()` here on purpose: every stored property has a default, so the
    // synthesized memberwise initialiser already serves `ScanMetrics()`, and
    // declaring one would collide with it. Putting `init(from:)` in an
    // EXTENSION rather than the main body is what keeps that synthesis alive —
    // an initialiser in the main body would suppress it and break every
    // `ScanMetrics()` call site.

    /// Every field optional on the way in, so a report written by any earlier
    /// build still loads. See the note on `PhaseTiming.init(from:)` — the same
    /// reasoning applies, and this type has gained fields three times already
    /// (scene tags, size counters, per-asset counts).
    ///
    /// `encode(to:)` stays synthesized: writing is always current-version.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: key) ?? 0 }

        scopeLabel = try c.decodeIfPresent(String.self, forKey: .scopeLabel) ?? ""
        deviceSummary = try c.decodeIfPresent(String.self, forKey: .deviceSummary) ?? ""
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)

        scopedAssetCount = try int(.scopedAssetCount)
        pagesProcessed = try int(.pagesProcessed)
        cacheHits = try int(.cacheHits)
        analysedFresh = try int(.analysedFresh)
        iCloudSkipped = try int(.iCloudSkipped)
        unavailable = try int(.unavailable)
        analysisFailures = try int(.analysisFailures)
        failureReasons = try c.decodeIfPresent([String: Int].self, forKey: .failureReasons) ?? [:]

        sizesFromCache = try int(.sizesFromCache)
        sizesMeasured = try int(.sizesMeasured)
        sizeWalkSeconds = try c.decodeIfPresent(Double.self, forKey: .sizeWalkSeconds) ?? 0

        phases = try c.decodeIfPresent([PhaseTiming].self, forKey: .phases) ?? []

        peakFootprintBytes = try c.decodeIfPresent(Int64.self, forKey: .peakFootprintBytes) ?? 0
        minAvailableBytes = try c.decodeIfPresent(Int64.self, forKey: .minAvailableBytes)
        memorySamples = try int(.memorySamples)
        previousScanDidNotFinish =
            try c.decodeIfPresent(Bool.self, forKey: .previousScanDidNotFinish) ?? false
        // A report written by a build that predates outcomes reached `save`,
        // and the only call site then was the end of a completed scan.
        outcome = try c.decodeIfPresent(Outcome.self, forKey: .outcome) ?? .completed
    }
}

// MARK: - Report

extension ScanMetrics {

    /// A plain-text report, formatted for copying out of the app and pasting
    /// somewhere it can be read. No emoji, no colour — it has to survive a
    /// paste into a text field.
    func report() -> String {
        var lines: [String] = []

        lines.append("TIDYGALLERY SCAN DIAGNOSTICS")
        if !deviceSummary.isEmpty { lines.append(deviceSummary) }
        if !scopeLabel.isEmpty { lines.append("Scope: \(scopeLabel)") }
        if let startedAt {
            // `Date.FormatStyle` rather than a shared `DateFormatter`: a static
            // formatter would be a non-Sendable global, which Swift 6 strict
            // concurrency rejects outright.
            lines.append("Started: \(startedAt.formatted(date: .abbreviated, time: .standard))")
        }
        if let seconds = wallClockSeconds {
            lines.append("Wall clock: \(Self.duration(seconds))")
        } else if startedAt != nil {
            lines.append("Wall clock: still running")
        }

        // What this report IS, before any of its numbers are read. A partial
        // report's figures are still meaningful — how far it got is the finding
        // — but reading them as a completed run would understate every total.
        switch outcome {
        case .completed:
            break
        case .inProgress:
            lines.append("")
            lines.append("INCOMPLETE — this run did not reach its end.")
            lines.append("If the app is not currently scanning, it was terminated")
            lines.append("mid-run. The figures below are how far it got.")
        case .cancelled:
            lines.append("")
            lines.append("STOPPED BY USER — not a failure. The figures below")
            lines.append("cover only the part that ran.")
        case .failed:
            lines.append("")
            lines.append("FAILED — the scan threw. The app was alive to record")
            lines.append("this, so it is a bug, not a memory limit.")
        }

        if previousScanDidNotFinish {
            lines.append("")
            lines.append("WARNING: the previous scan started but never finished.")
            lines.append("That is what an out-of-memory termination looks like.")
        }

        lines.append("")
        lines.append("VOLUME")
        lines.append("  Assets in scope:    \(scopedAssetCount)")
        lines.append("  Pages processed:    \(pagesProcessed)")
        lines.append("  Processed:          \(processedCount)")
        lines.append("  From cache:         \(cacheHits)\(Self.percentSuffix(cacheHitRate))")
        lines.append("  Freshly analysed:   \(analysedFresh)")
        lines.append("  Skipped (iCloud):   \(iCloudSkipped)")
        lines.append("  Unavailable:        \(unavailable)")
        lines.append("  Analysis failures:  \(analysisFailures)")

        if !failureReasons.isEmpty {
            lines.append("")
            lines.append("FAILURE REASONS")
            for (reason, count) in failureReasons.sorted(by: { $0.value > $1.value }) {
                lines.append("  \(count)x  \(reason)")
            }
        }

        if sizesFromCache + sizesMeasured > 0 {
            lines.append("")
            lines.append("ON-DISK SIZES")
            lines.append("  From cache:         \(sizesFromCache)\(Self.percentSuffix(sizeCacheHitRate))")
            lines.append("  Freshly measured:   \(sizesMeasured)")
            if let perSize = millisecondsPerFreshSize {
                lines.append("  " + String(format: "Cost per measure:   %.1f ms", perSize))
            }
        }

        lines.append("")
        lines.append("MEMORY")
        lines.append("  Peak footprint:     \(Self.bytes(peakFootprintBytes))")
        if let available = minAvailableBytes {
            lines.append("  Min headroom:       \(Self.bytes(available))")
        } else {
            lines.append("  Min headroom:       unavailable on this platform")
        }
        lines.append("  Samples:            \(memorySamples)")

        if !phases.isEmpty {
            lines.append("")
            lines.append("TIME BY PHASE")
            lines.append("  (Image load and Vision run concurrently, so their")
            lines.append("   totals legitimately exceed the wall clock above.)")
            let width = phases.map(\.name.count).max() ?? 0
            for phase in phases {
                let name = phase.name.padding(toLength: max(width, 18), withPad: " ", startingAt: 0)
                let total = Self.duration(phase.totalSeconds)
                let average = String(format: "%.1f ms avg", phase.averageMilliseconds)
                var line = "  \(name)  \(total)  (\(phase.count)x, \(average))"
                if let perAsset = phase.millisecondsPerAsset {
                    line += String(format: "  [%d assets, %.2f ms each]", phase.assetsSeen, perAsset)
                } else if phase.assetsSeen > 0 {
                    // Count but no rate: too small a sample to tell the fixed
                    // cost of the query from the marginal cost per asset.
                    line += String(format: "  [%d assets]", phase.assetsSeen)
                }
                lines.append(line)
            }
        }

        lines.append("")
        lines.append("THROUGHPUT")
        if let rate = photosPerSecond {
            lines.append("  " + String(format: "%.1f photos/sec overall", rate))
        }
        if let perPhoto = millisecondsPerFreshPhoto {
            lines.append("  " + String(format: "%.0f ms per fresh photo (serial cost)", perPhoto))
        }
        if let factor = measuredConcurrencyFactor {
            lines.append("  " + String(format: "%.1fx concurrency achieved", factor))
        }
        switch projection(forFreshPhotos: 20_000) {
        case let .available(seconds):
            lines.append("  Projected for 20,000 uncached photos: \(Self.duration(seconds))")
        case let .tooFewSamples(fresh, needed):
            lines.append("  Projected for 20,000: not shown — only \(fresh) photo(s)")
            lines.append("  analysed fresh, too few to extrapolate from (needs \(needed)).")
        case .notYet:
            break   // nothing analysed fresh yet, or the scan is still running
        }

        return lines.joined(separator: "\n")
    }

    private static func percentSuffix(_ fraction: Double?) -> String {
        guard let fraction else { return "" }
        return String(format: " (%.0f%%)", fraction * 100)
    }

    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: value)
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }
}
