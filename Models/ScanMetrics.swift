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

    var id: String { name }

    var averageMilliseconds: Double {
        count > 0 ? (totalSeconds / Double(count)) * 1000 : 0
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

    // MARK: - Recording

    /// Adds time to a phase, creating it on first use and preserving the order
    /// phases were first seen in.
    mutating func record(_ name: String, seconds: Double, count: Int = 1) {
        guard seconds.isFinite, seconds >= 0 else { return }
        if let index = phases.firstIndex(where: { $0.name == name }) {
            phases[index].totalSeconds += seconds
            phases[index].count += count
        } else {
            phases.append(PhaseTiming(name: name, totalSeconds: seconds, count: count))
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

    /// Projected wall clock for a library of `assetCount` photos, assuming none
    /// are cached. Rough by construction — it extrapolates the per-photo cost
    /// measured here — but it answers "will 20k photos take 4 minutes or 40?"
    func projectedSeconds(forFreshPhotos assetCount: Int) -> Double? {
        guard
            let perPhotoMs = millisecondsPerFreshPhoto,
            let seconds = wallClockSeconds,
            seconds > 0,          // a zero wall clock would make the factor infinite
            analysedFresh > 0
        else { return nil }
        // Analysis runs concurrently, so per-photo Vision+load time overstates
        // wall clock. Scale by the measured concurrency factor instead of
        // assuming the configured limit was actually achieved.
        let serialSeconds = (perPhotoMs / 1000) * Double(analysedFresh)
        let concurrencyFactor = serialSeconds > 0 ? serialSeconds / seconds : 1
        guard concurrencyFactor > 0 else { return nil }
        return (perPhotoMs / 1000) * Double(assetCount) / concurrencyFactor
    }

    /// Nothing has been recorded yet.
    var isEmpty: Bool { startedAt == nil && processedCount == 0 }
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
                lines.append("  \(name)  \(total)  (\(phase.count)x, \(average))")
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
        if let projected = projectedSeconds(forFreshPhotos: 20_000) {
            lines.append("  Projected for 20,000 uncached photos: \(Self.duration(projected))")
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
