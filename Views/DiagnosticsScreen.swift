//
//  DiagnosticsScreen.swift
//  TidyGallery
//
//  Shows what the last scan actually cost, and lets it leave the device.
//
//  This screen exists for one job: validating the app's memory and performance
//  claims against a real 20,000-photo library. The whole design — paged fetches,
//  bounded concurrency, downscaled analysis images — is a set of assertions that
//  had never been measured on hardware. Reading numbers off a phone screen and
//  retyping them is how measurements get lost, so everything here is also
//  available as one block of shareable plain text.
//
//  It updates live: `metrics` is observed, so leaving this open during a scan
//  shows footprint and headroom moving in real time, which is exactly when a
//  memory problem is visible.
//

import SwiftUI

struct DiagnosticsScreen: View {
    let coordinator: LibraryScanCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var showingRawReport = false

    /// Live metrics when a scan has run this launch; otherwise the last run's,
    /// restored from disk — so the numbers survive the app being killed, which
    /// is precisely the case worth investigating.
    private var metrics: ScanMetrics {
        coordinator.metrics.isEmpty ? (ScanMetricsStore.load() ?? coordinator.metrics)
                                    : coordinator.metrics
    }

    /// The report from a run that was killed, set aside so this launch's scan
    /// can't overwrite it. Shown alongside the current one rather than instead
    /// of it: on a large library the interesting comparison is how far the dead
    /// run got versus how far this one is getting.
    private var interrupted: ScanMetrics? { ScanMetricsStore.loadInterrupted() }

    /// Whether a scan is running *right now*.
    ///
    /// Was `startedAt != nil && finishedAt == nil`, which is also the exact
    /// shape of a checkpointed report from a run that was killed — so the one
    /// case this screen exists to explain was labelled "Scan in progress —
    /// updating live" and its "terminated mid-run" notice could never appear.
    /// Asking the coordinator whether it is actually scanning is both simpler
    /// and true.
    private var isLive: Bool {
        coordinator.isScanning || coordinator.analysisProgress != nil
    }

    /// Failure messages, worst first. A named tuple rather than iterating the
    /// dictionary inline, so `ForEach` has a concrete, stable identity to key on.
    private var sortedFailures: [(reason: String, count: Int)] {
        metrics.failureReasons
            .map { (reason: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        NavigationStack {
            List {
                if metrics.isEmpty {
                    emptySection
                } else {
                    if metrics.previousScanDidNotFinish || ScanMetricsStore.hasEverBeenInterrupted {
                        interruptionSection
                    }
                    contextSection
                    memorySection
                    volumeSection
                    if metrics.sizesFromCache + metrics.sizesMeasured > 0 { sizesSection }
                    if !metrics.failureReasons.isEmpty { failuresSection }
                    timingSection
                    throughputSection
                    exportSection
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingRawReport) {
                rawReportSheet
            }
        }
        .tint(Theme.Colors.accent)
    }

    // MARK: Sections

    private var emptySection: some View {
        Section {
            Text("No scan has been measured yet. Run a scan and come back — the numbers are recorded automatically.")
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    /// The headline finding, when there is one. An interrupted scan is the
    /// signature of an out-of-memory termination, and it deserves to be the
    /// first thing on the screen rather than a footnote.
    private var interruptionSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("A scan was terminated mid-run")
                        .fontWeight(.semibold)
                    Text("The app started a scan and never reached the end of it. That is what iOS killing the app for using too much memory looks like from the inside — there is no crash log to find. Try a narrower scan scope and compare the peak footprint below.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.destructive)
            }

            // The numbers from the run that died. Without these the warning is
            // just an assertion that something went wrong; with them it says
            // how far the app got and how little headroom was left when iOS
            // stopped it, which is the actual finding.
            if let dead = interrupted {
                VStack(alignment: .leading, spacing: 2) {
                    Text("That run reached:")
                        .font(.footnote.weight(.semibold))
                    Text("\(dead.processedCount) of \(dead.scopedAssetCount) photos · \(dead.pagesProcessed) pages")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text("peak \(ScanMetrics.bytes(dead.peakFootprintBytes))\(dead.minAvailableBytes.map { ", headroom down to \(ScanMetrics.bytes($0))" } ?? "")")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                ShareLink(item: dead.report()) {
                    Label("Share the interrupted run's report", systemImage: "square.and.arrow.up")
                        .font(.footnote)
                }
            }

            Button("Clear this warning") {
                ScanMetricsStore.clearInterruptionHistory()
            }
            .font(.footnote)
        }
    }

    private var contextSection: some View {
        Section("Run") {
            if isLive {
                Label("Scan in progress — updating live", systemImage: "waveform")
                    .foregroundStyle(Theme.Colors.accent)
                    .font(.footnote)
            } else {
                outcomeLabel
            }
            row("Device", metrics.deviceSummary)
            row("Scope", metrics.scopeLabel)
            if let seconds = metrics.wallClockSeconds {
                row("Wall clock", ScanMetrics.duration(seconds))
            }
        }
    }

    /// What this report is, before any of its numbers get read.
    ///
    /// A checkpointed report left in `.inProgress` by a scan that isn't running
    /// any more is the fingerprint of a kill — and the figures it holds are the
    /// most useful thing about it, since they say how far the app got before
    /// iOS stopped it. Reading them as a completed run would understate every
    /// total instead.
    @ViewBuilder private var outcomeLabel: some View {
        switch metrics.outcome {
        case .completed:
            EmptyView()
        case .inProgress:
            Label {
                Text("Incomplete — this run did not reach its end. The figures below are how far it got.")
                    .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.destructive)
            }
        case .cancelled:
            Label {
                Text("You stopped this scan. The figures below cover only the part that ran.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.textSecondary)
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        case .failed:
            Label {
                Text("This scan failed. The app was running when it happened, so this is a bug to fix rather than a memory limit — see the failure reasons below.")
                    .font(.footnote)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(Theme.Colors.destructive)
            }
        }
    }

    /// Deliberately above volume and timing: memory is the question this whole
    /// exercise exists to answer.
    private var memorySection: some View {
        Section {
            row("Peak footprint", ScanMetrics.bytes(metrics.peakFootprintBytes))
            if let available = metrics.minAvailableBytes {
                row("Lowest headroom", ScanMetrics.bytes(available))
            } else {
                row("Lowest headroom", "unavailable")
            }
            row("Samples", "\(metrics.memorySamples)")
        } header: {
            Text("Memory")
        } footer: {
            Text("Headroom is how much this app could still allocate before iOS would kill it. It matters more than the peak, because the limit differs by device. If it drops into the low tens of MB, the design is too close to the edge.")
        }
    }

    private var volumeSection: some View {
        Section {
            row("Assets in scope", "\(metrics.scopedAssetCount)")
            row("Pages processed", "\(metrics.pagesProcessed)")
            row("From cache", "\(metrics.cacheHits)")
            row("Freshly analysed", "\(metrics.analysedFresh)")
            row("Skipped (iCloud)", "\(metrics.iCloudSkipped)")
            row("Unavailable", "\(metrics.unavailable)")
            row("Analysis failures", "\(metrics.analysisFailures)")
        } header: {
            Text("Volume")
        }
    }

    private var sizesSection: some View {
        Section {
            row("From cache", "\(metrics.sizesFromCache)")
            row("Freshly measured", "\(metrics.sizesMeasured)")
            if let perSize = metrics.millisecondsPerFreshSize {
                row("Cost per measure", String(format: "%.1f ms", perSize))
            }
        } header: {
            Text("On-disk sizes")
        } footer: {
            Text("Reading a file's size costs a Photos lookup, so sizes are cached and only re-measured when a photo changes. On a second scan almost all of these should come from cache.")
        }
    }

    private var failuresSection: some View {
        Section {
            ForEach(sortedFailures, id: \.reason) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(failure.count)x")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text(failure.reason)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Why photos failed")
        } footer: {
            Text("A handful is normal. Thousands of the same message means a systematic problem, not bad photos.")
        }
    }

    private var timingSection: some View {
        Section {
            ForEach(metrics.phases) { phase in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.name)
                        Text(subtitle(for: phase))
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    Spacer()
                    Text(ScanMetrics.duration(phase.totalSeconds))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        } header: {
            Text("Time by phase")
        } footer: {
            Text("Image load, Vision analysis and the indented metadata fetches all run several things at a time, so their totals legitimately add up to more than the wall clock.")
        }
    }

    /// Per-asset cost where the phase counts assets, otherwise the plain average.
    /// The per-asset figure is the one that extrapolates to a large library.
    private func subtitle(for phase: PhaseTiming) -> String {
        let base = "\(phase.count)x · \(String(format: "%.1f", phase.averageMilliseconds)) ms avg"
        if let perAsset = phase.millisecondsPerAsset {
            return base + " · \(phase.assetsSeen) assets, \(String(format: "%.2f", perAsset)) ms each"
        }
        // Count without a rate: too few assets to separate the fixed cost of
        // the query from the marginal cost per asset.
        guard phase.assetsSeen > 0 else { return base }
        return base + " · \(phase.assetsSeen) assets"
    }

    private var throughputSection: some View {
        Section {
            if let rate = metrics.photosPerSecond {
                row("Overall", String(format: "%.1f photos/sec", rate))
            }
            if let perPhoto = metrics.millisecondsPerFreshPhoto {
                row("Per fresh photo", String(format: "%.0f ms", perPhoto))
            }
            if let factor = metrics.measuredConcurrencyFactor {
                row("Concurrency achieved", String(format: "%.1fx", factor))
            }
            switch metrics.projection(forFreshPhotos: 20_000) {
            case let .available(seconds):
                row("Projected: 20,000 photos", ScanMetrics.duration(seconds))
            case .tooFewSamples:
                row("Projected: 20,000 photos", "too few photos")
            case .notYet:
                EmptyView()
            }
        } header: {
            Text("Throughput")
        } footer: {
            Text(projectionFooter)
        }
    }

    /// Explains an absent projection rather than leaving a hole, since "no
    /// number" and "a number I'm hiding from you" read very differently.
    private var projectionFooter: String {
        // Driven by the same value as the row above it, so the two can never
        // give different explanations for the same missing number.
        switch metrics.projection(forFreshPhotos: 20_000) {
        case .available, .notYet:
            return "The projection extrapolates the per-photo cost measured here, at the concurrency actually achieved. It is a rough order of magnitude, not a promise."
        case let .tooFewSamples(fresh, needed):
            return """
            Only \(fresh) photo(s) were analysed fresh this run — fewer than the \(needed) needed \
            to extrapolate, because a small batch can't fill the analysis pool and carries all of \
            Vision's one-time startup cost. Rescan after adding photos, or clear the cache, for a \
            projection worth reading.
            """
        }
    }

    private var exportSection: some View {
        Section {
            ShareLink(item: metrics.report()) {
                Label("Share report", systemImage: "square.and.arrow.up")
            }
            Button {
                showingRawReport = true
            } label: {
                Label("View as text", systemImage: "doc.plaintext")
            }
        } footer: {
            Text("Plain text, no photo content — just counts, timings and memory figures.")
        }
    }

    // MARK: Raw report

    private var rawReportSheet: some View {
        NavigationStack {
            ScrollView {
                Text(metrics.report())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingRawReport = false }
                }
            }
        }
    }

    // MARK: Row

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }
}
