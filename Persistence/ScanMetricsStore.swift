//
//  ScanMetricsStore.swift
//  TidyGallery
//
//  Persists the last scan's diagnostics, and — more importantly — detects the
//  one failure mode that leaves no other trace.
//
//  Detecting an out-of-memory kill
//  ------------------------------
//  When iOS jetsams an app for exceeding its memory limit, the app does not get
//  to run any code: no `catch`, no `deinit`, no crash handler of ours. From
//  inside the app the event is invisible. The only way to observe it is
//  after the fact, on the next launch.
//
//  So a scan writes a "started" marker before it begins and clears it when it
//  finishes. If a later launch finds the marker still set, the previous scan was
//  terminated mid-flight — which on a photo-analysis pass over a large library
//  is an OOM kill until proven otherwise. That single boolean is the most
//  valuable thing this file produces.
//
//  Everything here is deliberately `UserDefaults`, not SwiftData: the marker
//  must survive a process kill that happens *during* SwiftData work, and it must
//  be readable before the model container is built.
//

import Foundation

enum ScanMetricsStore {

    private static let inFlightKey = "diagnostics.scanInFlight"
    private static let lastMetricsKey = "diagnostics.lastMetrics"
    private static let previousDidNotFinishKey = "diagnostics.previousScanDidNotFinish"
    /// Set aside from `lastMetricsKey` when a run is found to have died, so the
    /// next scan can't overwrite it. See `markScanStarted`.
    private static let interruptedMetricsKey = "diagnostics.interruptedMetrics"

    private static var defaults: UserDefaults { .standard }

    // MARK: - In-flight marker

    /// Call at the start of every scan. Also latches whether the *previous*
    /// scan finished, before overwriting the marker.
    ///
    /// - Returns: `true` if the previous scan started but never finished.
    @discardableResult
    @MainActor
    static func markScanStarted() -> Bool {
        let previousDidNotFinish = defaults.bool(forKey: inFlightKey)
        if previousDidNotFinish {
            // Latch it: the fact outlives this scan, so the Diagnostics screen
            // can still report it after a subsequent successful run.
            defaults.set(true, forKey: previousDidNotFinishKey)

            // Preserve the dead run's numbers before this one starts writing
            // over them.
            //
            // Checkpointing was added so an out-of-memory kill would leave its
            // figures behind — but it wrote to the same key every scan uses, and
            // Diagnostics is only reachable *after* starting a scan. So the
            // user's first act on relaunch (tap Scan, wait, open Diagnostics)
            // destroyed the very report they were going to read, one page in.
            // The saving throw arrives about ten seconds too late to be useful.
            //
            // Copying it aside here — before the new scan's first checkpoint —
            // is what actually makes the dead run readable.
            if let dead = defaults.data(forKey: lastMetricsKey) {
                defaults.set(dead, forKey: interruptedMetricsKey)
            }
        }
        defaults.set(true, forKey: inFlightKey)
        // A new run gets a fresh throttle, or a scan starting within the window
        // of the previous one's last write would silently skip its first page.
        lastCheckpoint = nil
        return previousDidNotFinish
    }

    /// The report from the last run that was terminated mid-flight, if any.
    ///
    /// This is the one the 20,000-photo test exists to produce: how far the app
    /// got, and what memory was doing, at the moment iOS killed it.
    static func loadInterrupted() -> ScanMetrics? {
        guard let data = defaults.data(forKey: interruptedMetricsKey) else { return nil }
        return try? JSONDecoder().decode(ScanMetrics.self, from: data)
    }

    /// Call when a scan completes (successfully or with a handled failure).
    static func markScanFinished() {
        defaults.set(false, forKey: inFlightKey)
    }

    /// Whether any previous scan has ever been terminated mid-flight.
    static var hasEverBeenInterrupted: Bool {
        defaults.bool(forKey: previousDidNotFinishKey)
    }

    /// Clears the interruption history (offered in Diagnostics, so a one-off
    /// from an old build doesn't shout forever).
    static func clearInterruptionHistory() {
        defaults.set(false, forKey: previousDidNotFinishKey)
        defaults.removeObject(forKey: interruptedMetricsKey)
    }

    /// Records that the user deliberately stopped a scan, so the next launch
    /// does not read it as a kill.
    ///
    /// Without this, force-quitting a twenty-minute scan and being jetsammed by
    /// it leave identical traces — and on a large library, abandoning a scan
    /// because the phone is hot is the *expected* behaviour, not an edge case.
    /// Conflating them would have made the interruption marker, which is the
    /// most valuable single bit this file produces, unreliable exactly when it
    /// started being exercised.
    static func markScanCancelled() {
        defaults.set(false, forKey: inFlightKey)
    }

    // MARK: - Last report

    static func save(_ metrics: ScanMetrics) {
        guard let data = try? JSONEncoder().encode(metrics) else { return }
        defaults.set(data, forKey: lastMetricsKey)
    }

    /// Writes a report that is still being filled in, so a run that never
    /// finishes still leaves its numbers behind.
    ///
    /// Why this exists
    /// ---------------
    /// `save` used to be called only at the end of a scan. That meant the one
    /// run most worth reading — the one iOS killed for memory at photo 12,000 of
    /// 20,000 — produced no figures at all: the next launch could report *that*
    /// it died, via the in-flight marker, but not how far it got, what the peak
    /// footprint was, or how little headroom was left. The instrumentation
    /// would have gone quiet at the precise moment it mattered.
    ///
    /// Throttled because it is called per page. At ~1 KB of JSON per write and
    /// one write per 200 photos, a 20,000-photo scan costs about 100 small
    /// `UserDefaults` writes against roughly twenty minutes of Vision work —
    /// but the throttle means a fast, fully-cached scan doesn't write on every
    /// page for no reason.
    /// `@MainActor` rather than `nonisolated(unsafe)`: the throttle below is
    /// mutable static state, and the scan pipeline that calls this is main-actor
    /// throughout. Saying so lets the compiler enforce it, instead of asserting
    /// safety in a comment the way an `unsafe` annotation would.
    @MainActor
    static func checkpoint(_ metrics: ScanMetrics) {
        let now = Date()
        if let last = lastCheckpoint, now.timeIntervalSince(last) < minimumCheckpointInterval {
            return
        }
        lastCheckpoint = now
        var partial = metrics
        partial.outcome = .inProgress
        save(partial)
    }

    /// Guards against checkpointing more often than is useful. Not `UserDefaults`
    /// — it only needs to live as long as the process does.
    @MainActor private static var lastCheckpoint: Date?
    private static let minimumCheckpointInterval: TimeInterval = 2

    static func load() -> ScanMetrics? {
        guard let data = defaults.data(forKey: lastMetricsKey) else { return nil }
        return try? JSONDecoder().decode(ScanMetrics.self, from: data)
    }
}
