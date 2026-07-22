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

    private static var defaults: UserDefaults { .standard }

    // MARK: - In-flight marker

    /// Call at the start of every scan. Also latches whether the *previous*
    /// scan finished, before overwriting the marker.
    ///
    /// - Returns: `true` if the previous scan started but never finished.
    @discardableResult
    static func markScanStarted() -> Bool {
        let previousDidNotFinish = defaults.bool(forKey: inFlightKey)
        // Latch it: the fact outlives this scan, so the Diagnostics screen can
        // still report it after a subsequent successful run.
        if previousDidNotFinish {
            defaults.set(true, forKey: previousDidNotFinishKey)
        }
        defaults.set(true, forKey: inFlightKey)
        return previousDidNotFinish
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
    }

    // MARK: - Last report

    static func save(_ metrics: ScanMetrics) {
        guard let data = try? JSONEncoder().encode(metrics) else { return }
        defaults.set(data, forKey: lastMetricsKey)
    }

    static func load() -> ScanMetrics? {
        guard let data = defaults.data(forKey: lastMetricsKey) else { return nil }
        return try? JSONDecoder().decode(ScanMetrics.self, from: data)
    }
}
