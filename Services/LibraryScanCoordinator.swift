//
//  LibraryScanCoordinator.swift
//  TidyGallery
//
//  Orchestrates the Phase 1 pipeline end-to-end and exposes progress to the UI.
//  This is the object a Phase 2 view model observes.
//
//  Flow per page (bounded memory):
//    fetch page (snapshots) → look up cache → analyse only cache-misses
//    (bounded concurrency) → persist new results → accumulate enriched assets.
//  After all pages: cluster (time-gate + visual) → score → publish stacks.
//

import Foundation
import Observation

/// One analysed photo's outcome, plus how long each stage of it took.
///
/// File scope on purpose: it's produced inside the nonisolated analysis task
/// group, and nesting it in the `@MainActor` coordinator would make it
/// main-actor isolated too.
///
/// Timings are carried back on the result rather than written to a shared
/// counter: the task group body is nonisolated and runs several photos at once,
/// so anything it touched directly would need an actor hop per photo. Returning
/// two `Double`s costs nothing and keeps the accumulation on the main actor,
/// where it's trivially race-free.
private struct PageResult: Sendable {
    enum Outcome: Sendable {
        case analysed(AnalyzedImage)
        /// The full-quality original lives only in iCloud and we may not fetch it.
        case inCloud
        /// Photos returned no usable image.
        case unavailable
        /// Vision threw. Carried (not thrown) so one bad photo cannot abort the
        /// whole scan — see `process(page:)`.
        case failed(String)
    }

    let index: Int
    let outcome: Outcome
    /// Seconds spent in the Photos image request (decode + downscale).
    let imageLoadSeconds: Double
    /// Seconds spent in Vision.
    let visionSeconds: Double
}

@MainActor
@Observable
final class LibraryScanCoordinator {

    // MARK: Observable state for the UI

    enum Phase: Sendable, Equatable {
        case idle
        case requestingAccess
        case scanning(analysed: Int, total: Int)
        case clustering
        case finished(stackCount: Int)
        case failed(String)
        case accessDenied
    }

    private(set) var phase: Phase = .idle
    private(set) var stacks: [PhotoStack] = []

    // MARK: Standalone cleanup categories (Phase 3)
    //
    // Each is a flat list the UI surfaces for manual review. NONE of these is
    // ever pre-selected for deletion — the user selects within each screen and
    // confirms, keeping the app's safety-first guarantee intact.

    /// All screenshots in the library.
    private(set) var screenshots: [PhotoAsset] = []

    /// All videos, for the "Large videos" screen (sorted by size in the UI).
    private(set) var largeVideos: [PhotoAsset] = []

    /// Live Photos + highest-resolution stills, for the "Big files" screen.
    private(set) var bigFileCandidates: [PhotoAsset] = []

    /// Videos detected as screen recordings.
    private(set) var screenRecordings: [PhotoAsset] = []

    /// Standalone stills that look clearly soft (surfacing only, never
    /// pre-selected). Excludes favorites and anything already in a duplicate stack.
    private(set) var blurryPhotos: [PhotoAsset] = []

    /// Content categories from on-device scene classification.
    private(set) var foodPhotos: [PhotoAsset] = []
    private(set) var petPhotos: [PhotoAsset] = []
    private(set) var documentPhotos: [PhotoAsset] = []
    private(set) var naturePhotos: [PhotoAsset] = []
    private(set) var selfiePhotos: [PhotoAsset] = []

    /// Reclaimable-space breakdown for the home dashboard.
    private(set) var storageSummary: StorageSummary = .empty

    /// The engine's confident, conservative recommendations: the pre-selected
    /// near-duplicate photos across all stacks, flattened for one-tap cleanup.
    private(set) var recommendedAssets: [PhotoAsset] = []

    /// Total on-disk size of the whole library, measured off-main once per scan.
    /// `nil` until the background measurement finishes.
    private(set) var totalLibraryBytes: Int64?

    /// Groups of byte-identical copies of the same image, found regardless of
    /// how far apart in time they were added.
    private(set) var exactDuplicateGroups: [[PhotoAsset]] = []

    /// The safe-to-delete copies from those groups (one copy of each is always
    /// kept, and favorites are never included).
    private(set) var exactDuplicateExtras: [PhotoAsset] = []

    /// Background task computing `totalLibraryBytes`.
    private var totalSizeTask: Task<Void, Never>?

    /// Background task computing `storageSummary` (sizes measured off-main).
    private var summaryTask: Task<Void, Never>?

    // Raw results of the last library enumeration, before the ignore list is
    // applied. Retained so a cheap re-filter doesn't need to walk the library
    // again (see `refreshDerivedCategories`).
    private var rawScreenshots: [PhotoAsset] = []
    private var rawVideos: [PhotoAsset] = []
    private var rawRecordings: [PhotoAsset] = []
    private var rawBigFiles: [PhotoAsset] = []
    private var rawSelfies: [PhotoAsset] = []
    private var rawExactDuplicateExtras: [PhotoAsset] = []

    // MARK: Collaborators

    private let library: PhotoLibraryService
    private let analyzer: ImageAnalyzer
    private let cache: AnalysisCacheStore
    private let ignoreList: IgnoreListStore

    /// Live analysis configuration. Mutable so the Settings screen can retune
    /// detection without a rebuild.
    private(set) var config: AnalysisConfiguration

    /// The user-facing subset of `config`, as chosen in Settings.
    private(set) var tuning: TuningSettings

    /// True while a settings change is being applied (may involve a re-scan).
    private(set) var isRetuning = false

    /// Assets the user has said "never suggest this again" about. Loaded from
    /// the ignore list at scan time and filtered out of every suggestion.
    private(set) var ignoredIDs: Set<PhotoAsset.ID> = []

    /// The ignored assets themselves, for the management screen.
    private(set) var ignoredAssets: [PhotoAsset] = []

    /// Progress of the background analysis pass. `nil` when nothing is running.
    struct ScanProgress: Sendable, Equatable {
        var done: Int
        var total: Int
        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }

    /// Non-`nil` while Vision analysis is still filling in duplicates and
    /// content categories. The home is usable throughout.
    private(set) var analysisProgress: ScanProgress?

    /// How many photos this scan couldn't analyse because they're stored in
    /// iCloud and downloading wasn't permitted. Surfaced to the user rather than
    /// silently dropping them.
    private(set) var iCloudSkippedCount = 0

    /// How much of the library the current scan covers.
    private(set) var scope: ScanScope = ScanScopeStore.load()

    /// Instrumentation for the current (or most recent) scan: where the time
    /// went, peak memory, and what couldn't be analysed. Surfaced by
    /// `DiagnosticsScreen`; costs a few integer increments per photo.
    private(set) var metrics = ScanMetrics()

    /// Samples memory and folds the reading into `metrics`. Cheap enough to call
    /// per page and every `memorySampleInterval` photos.
    private func sampleMemory() {
        let sample = MemoryProbe.sample()
        metrics.sampleMemory(
            footprintBytes: sample.footprintBytes,
            availableBytes: sample.availableBytes
        )
    }

    private let memorySampleInterval = 25

    /// Adds the time since `start` to `metrics` under `phase`.
    ///
    /// Deliberately a plain function taking an instant, rather than a generic
    /// `timed { … }` wrapper: a generic, `rethrows`, closure-taking helper has to
    /// infer its result type through multi-statement and `async` closure bodies,
    /// and gets tangled in actor-isolation inference at the one call site that
    /// lives inside a task group. Two lines at each call site cost nothing and
    /// can't misbehave.
    ///
    /// `ContinuousClock` rather than `Date`: it's monotonic, so a clock
    /// adjustment mid-scan can't produce a negative or wildly wrong duration.
    private func recordPhase(_ phase: String, since start: ContinuousClock.Instant) {
        metrics.record(phase, seconds: (ContinuousClock.now - start).inSeconds)
    }

    /// Photos processed so far in the current scan, and the scoped total.
    private var scanProgress = 0
    private var scanTotal = 0

    /// Publishes analysis progress. Throttled to every `progressReportInterval`
    /// photos: updating an `@Observable` property per photo would re-render the
    /// UI thousands of times during a large scan.
    private func reportProgress(force: Bool = false) {
        guard force || scanProgress % progressReportInterval == 0 else { return }
        analysisProgress = ScanProgress(done: scanProgress, total: scanTotal)
    }

    private let progressReportInterval = 10

    /// Bounds how many images are decoded + analysed at once. Tuned low to keep
    /// peak memory and thermals in check on large libraries; raise cautiously.
    private let maxConcurrentAnalyses: Int

    /// The enriched, analysed asset set from the last scan — retained so live
    /// library changes can be applied as deltas without re-scanning everything.
    private var analysedAssets: [PhotoAsset] = []

    /// Live library-change observer, started after the first successful scan.
    private var changeObserver: PhotoLibraryChangeObserver?
    private var observationTask: Task<Void, Never>?

    /// Debounce handle for the expensive re-cluster + category re-fetch. A burst
    /// of change events (several quick deletions, a batch import) reschedules
    /// this so the heavy pass runs once, after things settle.
    private var recomputeTask: Task<Void, Never>?

    init(
        library: PhotoLibraryService,
        analyzer: ImageAnalyzer,
        cache: AnalysisCacheStore,
        ignoreList: IgnoreListStore,
        tuning: TuningSettings = TuningStore.load(),
        maxConcurrentAnalyses: Int = 4
    ) {
        self.library = library
        self.analyzer = analyzer
        self.cache = cache
        self.ignoreList = ignoreList
        self.tuning = tuning
        self.config = tuning.applied()
        self.maxConcurrentAnalyses = maxConcurrentAnalyses
    }

    // MARK: - Public entry point

    /// Runs a full scan and publishes the resulting stacks. Safe to call again;
    /// cached assets are skipped so subsequent runs are fast.
    func scan() async {
        // Start a fresh measurement, and find out whether the *last* scan ever
        // reached its end. It not having done so is the only observable trace an
        // out-of-memory kill leaves behind — see `ScanMetricsStore`.
        let previousDidNotFinish = ScanMetricsStore.markScanStarted()
        metrics = ScanMetrics()
        metrics.startedAt = Date()
        metrics.scopeLabel = scope.label
        metrics.deviceSummary = DeviceSummary.current
        metrics.previousScanDidNotFinish = previousDidNotFinish
        sampleMemory()

        phase = .requestingAccess
        let access = await library.requestAccess()
        switch access {
        case .denied, .restricted:
            // Clear the marker: a refused scan is a normal outcome, and leaving
            // it set would make the next launch cry OOM.
            ScanMetricsStore.markScanFinished()
            phase = .accessDenied
            return
        case .notDetermined:
            ScanMetricsStore.markScanFinished()
            phase = .failed("Photo access was not granted.")
            return
        case .authorized, .limited:
            break   // `.limited` still works; we scan whatever we're allowed.
        }

        // Access is settled — move off "Requesting photo access…" immediately.
        phase = .scanning(analysed: 0, total: 0)
        library.scope = scope

        // Load the user's "never suggest this again" decisions up front so every
        // category built below can exclude them.
        ignoredIDs = (try? await ignoreList.allIgnoredIDs()) ?? []

        // STEP 1 — the fast pass. Screenshots, videos, screen recordings and big
        // files come from metadata alone: no Vision, no per-photo image loads.
        // Publishing these first means the home is usable within a second or two
        // instead of after the whole library has been analysed.
        analysedAssets = []
        stacks = []
        let metadataStart = ContinuousClock.now
        refreshCategories()
        recordPhase(ScanMetrics.Phase.metadataPass, since: metadataStart)
        phase = .finished(stackCount: 0)

        // STEP 2 — the slow pass, in the background. Duplicates and the content
        // categories need Vision, so they fill in progressively while the user
        // is already free to clean up the fast categories.
        await runAnalysis()

        // The scan reached its end, so this launch is not the one that died.
        metrics.finishedAt = Date()
        sampleMemory()
        ScanMetricsStore.markScanFinished()
        ScanMetricsStore.save(metrics)

        startObserving()
    }

    /// Analyses the scoped library newest-first, publishing results as it goes
    /// rather than only at the end.
    private func runAnalysis() async {
        scanProgress = 0
        scanTotal = 0
        iCloudSkippedCount = 0
        analysisProgress = ScanProgress(done: 0, total: 0)
        defer { analysisProgress = nil }

        var enriched: [PhotoAsset] = []
        do {
            for await page in library.assetPages() {
                scanTotal = page.totalCount
                metrics.scopedAssetCount = page.totalCount
                let (pageAssets, _) = try await process(page: page)
                enriched.append(contentsOf: pageAssets)
                analysedAssets = enriched
                metrics.pagesProcessed += 1
                // Once per page is the meaningful sampling point: peak footprint
                // is reached while a page's images are in flight, and the page
                // boundary is where everything should have been released again.
                sampleMemory()

                // Re-derive often at the start (so something appears quickly),
                // then periodically — re-clustering every page would grow costly
                // as the working set builds up.
                if page.pageIndex < 3 || page.pageIndex % 5 == 0 || page.isLastPage {
                    stacks = buildStacks(from: analysedAssets)
                    refreshDerivedCategories()
                }
                reportProgress(force: true)
            }
        } catch {
            metrics.finishedAt = Date()
            ScanMetricsStore.markScanFinished()
            ScanMetricsStore.save(metrics)
            phase = .failed(error.localizedDescription)
            return
        }

        analysedAssets = enriched
        stacks = buildStacks(from: enriched)
        refreshDerivedCategories()
        measureTotalLibrarySize()
        phase = .finished(stackCount: stacks.count)
    }

    /// Change how much of the library is scanned, then rescan.
    func rescan(scope newScope: ScanScope) async {
        scope = newScope
        ScanScopeStore.save(newScope)
        analysedAssets = []
        stacks = []
        await scan()
    }

    // MARK: - Incremental updates

    /// Begin observing the photo library. Idempotent — safe to call after every
    /// scan; only the first call actually registers.
    private func startObserving() {
        guard changeObserver == nil else { return }
        let observer = PhotoLibraryChangeObserver()
        changeObserver = observer
        observationTask = Task { [weak self] in
            for await change in observer.changes {
                await self?.apply(change)
            }
        }
    }

    /// Apply a library delta: purge removed assets from the cache and working
    /// set, (re)analyse only the changed/inserted ones, then re-cluster. The
    /// heavy full-library scan is never repeated.
    private func apply(_ change: LibraryChange) async {
        // Removals.
        if !change.removedIdentifiers.isEmpty {
            try? await cache.purge(ids: change.removedIdentifiers)
            let removed = Set(change.removedIdentifiers)
            analysedAssets.removeAll { removed.contains($0.id) }
        }

        // Insertions / modifications.
        if !change.changedIdentifiers.isEmpty {
            let snapshots = library.snapshots(for: change.changedIdentifiers)
            let keys = snapshots.map { (id: $0.id, modificationDate: $0.modificationDate) }
            let cached = (try? await cache.freshAnalysis(for: keys)) ?? [:]

            var updated: [PhotoAsset] = []
            for var asset in snapshots {
                if let hit = cached[asset.id] {
                    asset.featurePrint = hit.featurePrint
                    asset.score = hit.score
                    asset.sceneTags = hit.sceneTags
                    asset.classificationLabels = hit.labels
                } else {
                    let imageResult = await library.analysisImage(
                        for: asset.id,
                        allowNetwork: tuning.analyseICloudPhotos
                    )
                    if case let .image(cgImage) = imageResult,
                       let result = try? await analyzer.analyze(
                           image: cgImage,
                           isFavorite: asset.isFavorite
                       ) {
                        asset.featurePrint = result.featurePrint
                        asset.score = result.score
                        asset.sceneTags = result.sceneTags
                        asset.classificationLabels = result.labels
                        try? await cache.store(
                            id: asset.id,
                            modificationDate: asset.modificationDate,
                            featurePrint: result.featurePrint,
                            score: result.score,
                            sceneTags: result.sceneTags,
                            labels: result.labels
                        )
                    }
                }
                if asset.isAnalysed { updated.append(asset) }
            }

            // Replace existing entries and add new ones.
            let updatedIDs = Set(updated.map(\.id))
            analysedAssets.removeAll { updatedIDs.contains($0.id) }
            analysedAssets.append(contentsOf: updated)
        }

        // Coalesce the expensive re-cluster + full category re-fetch. Cheap
        // bookkeeping above (cache purge, working-set delta) has already run;
        // the heavy pass is debounced so a burst of changes triggers it once.
        scheduleRecompute()
    }

    // MARK: - Cleanup categories

    /// Recomputes every standalone cleanup category. Cheap metadata fetches plus
    /// the blurry-singles derivation from already-analysed assets; safe to call
    /// after a full scan and after each library delta.
    /// Full refresh: re-enumerate the library, then re-derive everything.
    /// Used after a scan, a library change, or a settings change.
    private func refreshCategories() {
        // One pass yields both videos and the screen-recording subset; fetching
        // them separately walked every video twice, with a PHAssetResource
        // lookup each time.
        let (videos, recordings) = library.fetchVideosAndScreenRecordings()
        rawScreenshots = library.fetchScreenshots()
        rawSelfies = library.fetchSelfies()
        rawVideos = videos
        rawRecordings = recordings
        rawBigFiles = computeBigFiles()
        refreshDerivedCategories()
    }

    /// Cheap refresh: re-filter the last enumeration and re-derive.
    ///
    /// Ignoring a photo used to trigger a full `refreshCategories()`, which
    /// re-enumerated the entire library just to hide one asset. Everything here
    /// works from lists already in memory.
    private func refreshDerivedCategories() {
        let start = ContinuousClock.now
        deriveCategories()
        recordPhase(ScanMetrics.Phase.derivation, since: start)
    }

    private func deriveCategories() {
        // Every category is filtered through `suggestable`, so a photo the user
        // chose to keep never reappears as a suggestion anywhere.
        screenshots = suggestable(rawScreenshots)
        largeVideos = suggestable(rawVideos)
        screenRecordings = suggestable(rawRecordings)
        bigFileCandidates = suggestable(rawBigFiles)
        exactDuplicateExtras = suggestable(rawExactDuplicateExtras)
        blurryPhotos = deriveBlurrySingles()
        foodPhotos = photosTagged(.food)
        petPhotos = photosTagged(.pets)
        documentPhotos = photosTagged(.documents)
        naturePhotos = photosTagged(.nature)
        selfiePhotos = suggestable(rawSelfies)
        stripIgnoredFromStackPreselections()
        recommendedAssets = recommendedDeletions()
        ignoredAssets = library.snapshots(for: Array(ignoredIDs))
        refreshStorageSummary()
    }

    /// Drops anything the user has chosen to keep.
    private func suggestable(_ assets: [PhotoAsset]) -> [PhotoAsset] {
        guard !ignoredIDs.isEmpty else { return assets }
        return assets.filter { !ignoredIDs.contains($0.id) }
    }

    /// An ignored photo stays visible inside its duplicate stack (removing it
    /// would make the group confusing), but is never pre-selected for deletion.
    private func stripIgnoredFromStackPreselections() {
        guard !ignoredIDs.isEmpty else { return }
        stacks = stacks.map { stack in
            let cleaned = stack.assetsPreselectedForDeletion.subtracting(ignoredIDs)
            guard cleaned != stack.assetsPreselectedForDeletion else { return stack }
            return PhotoStack(
                id: stack.id,
                assets: stack.assets,
                bestShotID: stack.bestShotID,
                rankedAssetIDs: stack.rankedAssetIDs,
                assetsPreselectedForDeletion: cleaned
            )
        }
    }

    /// The engine's safe deletion suggestions, flattened into one list: the
    /// conservatively pre-selected near-duplicates, plus every redundant copy of
    /// a byte-identical image (the safest possible deletion — an exact copy is
    /// always kept). De-duplicated in case an asset qualifies both ways.
    private func recommendedDeletions() -> [PhotoAsset] {
        let preselected = stacks.flatMap { stack in
            stack.assets.filter { stack.assetsPreselectedForDeletion.contains($0.id) }
        }
        var seen = Set<PhotoAsset.ID>()
        let combined = (preselected + exactDuplicateExtras).filter { seen.insert($0.id).inserted }
        // Belt-and-braces: an ignored photo must never be recommended.
        return suggestable(combined)
    }

    /// Kick off the (heavy, off-main) library size measurement. One pass serves
    /// two jobs: the dashboard's total, and the per-asset sizes that
    /// `ExactDuplicateFinder` needs to spot byte-identical copies. Runs once per
    /// full scan; results land when ready.
    private func measureTotalLibrarySize() {
        let assets = analysedAssets
        let finder = ExactDuplicateFinder(config: config)

        totalSizeTask?.cancel()
        totalSizeTask = Task { [weak self, library] in
            let start = ContinuousClock.now
            let sizes = await library.libraryFileSizes()
            guard !Task.isCancelled else { return }
            let measurementSeconds = (ContinuousClock.now - start).inSeconds

            let total = sizes.values.reduce(0, +)
            let groups = finder.groups(from: assets, sizes: sizes)
            let extras = finder.extras(in: groups)
            guard !Task.isCancelled else { return }

            self?.applyLibraryMeasurements(
                total: total,
                groups: groups,
                extras: extras,
                measurementSeconds: measurementSeconds
            )
        }
    }

    /// Publish the background measurement results and refresh anything derived
    /// from them (recommendations and the reclaimable-space breakdown).
    private func applyLibraryMeasurements(
        total: Int64,
        groups: [[PhotoAsset]],
        extras: [PhotoAsset],
        measurementSeconds: Double = 0
    ) {
        metrics.record(ScanMetrics.Phase.sizeMeasurement, seconds: measurementSeconds)
        totalLibraryBytes = total
        exactDuplicateGroups = groups
        rawExactDuplicateExtras = extras
        // Respect "don't suggest again" for copies found by the background pass.
        exactDuplicateExtras = suggestable(extras)
        recommendedAssets = recommendedDeletions()
        refreshStorageSummary()
    }

    /// Recomputes the dashboard's reclaimable-space breakdown.
    ///
    /// Ids are gathered on the main actor (cheap), then the real on-disk sizes
    /// are measured **off** the main actor — this set now includes every
    /// screenshot and every duplicate extra, which can run to thousands of
    /// assets, far too many to walk on the main thread without a visible hitch.
    ///
    /// Duplicates are counted as their *potential* saving (everything except each
    /// group's best shot) to match the card's "up to X" framing. The conservative
    /// pre-selected subset remains what "Recommended cleanup" acts on.
    private func refreshStorageSummary() {
        let input = StorageSummaryBuilder.Input(
            exactDuplicateIDs: Set(exactDuplicateExtras.map(\.id)),
            duplicateIDs: Set(stacks.flatMap { stack in
                stack.assets.map(\.id).filter { $0 != stack.bestShotID }
            }),
            videoIDs: Set(largeVideos.map(\.id)),
            bigFileIDs: Set(bigFileCandidates.map(\.id)),
            recordingIDs: Set(screenRecordings.map(\.id)),
            screenshotIDs: Set(screenshots.map(\.id))
        )

        guard !input.isEmpty else {
            summaryTask?.cancel()
            storageSummary = .empty
            return
        }

        summaryTask?.cancel()
        summaryTask = Task { [weak self, library] in
            let sizes = await library.assetFileSizes(for: Array(input.unionIDs))
            guard !Task.isCancelled else { return }
            self?.storageSummary = StorageSummaryBuilder.build(input, sizes: sizes)
        }
    }

    /// Analysed stills carrying a given content tag, newest first. Surfacing-only
    /// (never pre-selected); videos are excluded since classification runs on
    /// still images.
    private func photosTagged(_ category: SceneCategory) -> [PhotoAsset] {
        suggestable(
            analysedAssets
                .filter { $0.mediaType == .image && $0.sceneTags.contains(category) }
                .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        )
    }

    /// Actual "big files": measures real on-disk size for the bounded candidate
    /// pool, keeps only those at or above the size floor, sorts largest-first and
    /// caps the count. Measuring here (not in the view) keeps the home card's
    /// count consistent with what the screen shows.
    private func computeBigFiles() -> [PhotoAsset] {
        let candidates = library.fetchLargeFileCandidates(stillLimit: config.bigFileCandidateStillLimit)
        guard !candidates.isEmpty else { return [] }
        let sizes = library.fileSizes(for: candidates.map(\.id))
        return candidates
            .filter { (sizes[$0.id] ?? 0) >= config.bigFileMinBytes }
            .sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
            .prefix(config.bigFileDisplayLimit)
            .map { $0 }
    }

    /// Standalone stills that look soft. Conservative, RELATIVE, and
    /// surfacing-only: never pre-selected for deletion. Excludes favorites and
    /// anything already grouped into a duplicate stack (so it isn't shown twice).
    ///
    /// A photo qualifies only when its sharpness is below BOTH an absolute
    /// ceiling AND the library's low-percentile floor — then capped. Because
    /// Laplacian sharpness scale varies by device and downscale, an absolute
    /// cutoff alone can flag everything; combining it with a percentile bounds
    /// the category to genuinely-relative-worst shots and never the whole library.
    private func deriveBlurrySingles() -> [PhotoAsset] {
        let grouped = Set(stacks.flatMap { $0.assets.map(\.id) })
        return BlurrySinglesSelector(config: config)
            .select(from: analysedAssets, excluding: grouped.union(ignoredIDs))
    }

    /// Debounced heavy recompute: re-clusters stacks from the current working
    /// set and re-fetches every category from the library. Rescheduling cancels
    /// any pending pass, so a burst of change events collapses to a single run.
    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.stacks = self.buildStacks(from: self.analysedAssets)
            self.refreshCategories()
            self.phase = .finished(stackCount: self.stacks.count)
        }
    }

    /// Immediately reconcile every published list after the user deletes assets
    /// from a category screen. This keeps the home counts and *other* category
    /// screens correct at once — cheap, in-memory, no library re-enumeration —
    /// rather than waiting for the debounced observer pass. The observer still
    /// fires and reconciles any external changes afterwards.
    func noteDeleted(ids: [PhotoAsset.ID]) {
        guard !ids.isEmpty else { return }
        let removed = Set(ids)
        analysedAssets.removeAll { removed.contains($0.id) }
        screenshots.removeAll { removed.contains($0.id) }
        largeVideos.removeAll { removed.contains($0.id) }
        bigFileCandidates.removeAll { removed.contains($0.id) }
        screenRecordings.removeAll { removed.contains($0.id) }
        blurryPhotos.removeAll { removed.contains($0.id) }
        foodPhotos.removeAll { removed.contains($0.id) }
        petPhotos.removeAll { removed.contains($0.id) }
        documentPhotos.removeAll { removed.contains($0.id) }
        naturePhotos.removeAll { removed.contains($0.id) }
        selfiePhotos.removeAll { removed.contains($0.id) }
        exactDuplicateExtras.removeAll { removed.contains($0.id) }
        exactDuplicateGroups = exactDuplicateGroups
            .map { $0.filter { !removed.contains($0.id) } }
            .filter { $0.count > 1 }
        pruneStacks(removing: removed)
        recommendedAssets = recommendedDeletions()
        refreshStorageSummary()
        phase = .finished(stackCount: stacks.count)
    }

    // MARK: - Retuning

    /// Adopt new detection settings from the Settings screen.
    ///
    /// Most knobs (duplicate similarity, blurry sensitivity, big-file floor) are
    /// applied while *deriving* categories, so they take effect immediately by
    /// re-clustering the working set already in memory — no re-analysis, no
    /// waiting. The two analysis-time knobs (scene confidence, selfie face size)
    /// are baked into cached results, so changing those discards the cache and
    /// re-scans.
    func applyTuning(_ newTuning: TuningSettings) async {
        guard newTuning != tuning else { return }
        let needsReanalysis = newTuning.requiresReanalysis(comparedTo: tuning)
        // Only scene/selfie changes invalidate stored results. Enabling iCloud
        // analysis just needs a rescan: previously-skipped photos have no cache
        // entry, and everything already analysed locally is still correct.
        let needsPurge = newTuning.requiresCachePurge(comparedTo: tuning)

        isRetuning = true
        defer { isRetuning = false }

        tuning = newTuning
        config = newTuning.applied()
        TuningStore.save(newTuning)
        await analyzer.updateConfiguration(config)

        if needsReanalysis {
            if needsPurge { try? await cache.purgeAll() }
            analysedAssets = []
            await scan()
        } else {
            stacks = buildStacks(from: analysedAssets)
            refreshCategories()
            phase = .finished(stackCount: stacks.count)
        }
    }

    // MARK: - Ignore list

    /// Mark assets as "never suggest again". Persisted, then every published
    /// list is refreshed so they disappear from suggestions immediately.
    func ignore(ids: [PhotoAsset.ID]) async {
        guard !ids.isEmpty else { return }
        try? await ignoreList.ignore(ids: ids)
        ignoredIDs.formUnion(ids)
        // Cheap: re-filter what we already have, no library enumeration.
        refreshDerivedCategories()
    }

    /// Stop ignoring assets — they become eligible for suggestions again.
    func stopIgnoring(ids: [PhotoAsset.ID]) async {
        guard !ids.isEmpty else { return }
        try? await ignoreList.unignore(ids: ids)
        ignoredIDs.subtract(ids)
        // Restoring can re-open duplicate suggestions, so re-cluster — but the
        // raw library lists are still valid, so no re-enumeration is needed.
        stacks = buildStacks(from: analysedAssets)
        refreshDerivedCategories()
    }

    /// Drop deleted assets from existing stacks without re-clustering. A stack
    /// that falls to a single photo is removed (no longer a cleanup group); if
    /// the best shot was deleted, the top surviving ranked photo inherits it.
    private func pruneStacks(removing removed: Set<PhotoAsset.ID>) {
        stacks = stacks.compactMap { $0.removing(removed) }
    }

    // MARK: - Per-page processing

    /// Analyses the cache-misses on a page and returns the enriched assets plus
    /// how many were freshly analysed (for progress).
    private func process(page: AssetPage) async throws -> (assets: [PhotoAsset], newlyAnalysed: Int) {
        // 1. Batch cache lookup.
        let keys = page.assets.map { (id: $0.id, modificationDate: $0.modificationDate) }
        let cacheStart = ContinuousClock.now
        let cached = try await cache.freshAnalysis(for: keys)
        recordPhase(ScanMetrics.Phase.cacheLookup, since: cacheStart)

        var enriched = page.assets
        var toAnalyse: [Int] = []   // indices into `enriched`

        for i in enriched.indices {
            if let hit = cached[enriched[i].id] {
                enriched[i].featurePrint = hit.featurePrint
                enriched[i].score = hit.score
                enriched[i].sceneTags = hit.sceneTags
                enriched[i].classificationLabels = hit.labels
                scanProgress += 1          // cache hits are progress too
                metrics.cacheHits += 1
            } else {
                toAnalyse.append(i)
            }
        }
        reportProgress(force: true)

        guard !toAnalyse.isEmpty else { return (enriched, 0) }

        // Read main-actor state ONCE here, while we're still on the main actor.
        // The task-group body below is a nonisolated context, so touching a
        // mutable `@MainActor` property (like `tuning`) from inside it is an
        // isolation error — capture the plain value instead.
        let allowNetwork = tuning.analyseICloudPhotos

        // 2. Analyse misses with bounded concurrency.
        return try await withThrowingTaskGroup(of: PageResult.self) { group in
            var inFlight = 0
            var iterator = toAnalyse.makeIterator()

            func addTask(_ index: Int) {
                let asset = enriched[index]
                group.addTask { [library, analyzer] in
                    let loadStart = ContinuousClock.now
                    let image = await library.analysisImage(for: asset.id, allowNetwork: allowNetwork)
                    let loadSeconds = (ContinuousClock.now - loadStart).inSeconds

                    switch image {
                    case let .image(cgImage):
                        let visionStart = ContinuousClock.now
                        do {
                            let result = try await analyzer.analyze(
                                image: cgImage,
                                isFavorite: asset.isFavorite
                            )
                            return PageResult(
                                index: index,
                                outcome: .analysed(result),
                                imageLoadSeconds: loadSeconds,
                                visionSeconds: (ContinuousClock.now - visionStart).inSeconds
                            )
                        } catch {
                            // Deliberately caught, not rethrown. A throw here
                            // would tear down the whole task group and fail the
                            // entire scan — so across a 20,000-photo library, a
                            // single image Vision dislikes would take everything
                            // with it. Instead the photo is counted as a failure
                            // and the scan carries on; the count and reason land
                            // in Diagnostics.
                            return PageResult(
                                index: index,
                                outcome: .failed(String(describing: error)),
                                imageLoadSeconds: loadSeconds,
                                visionSeconds: (ContinuousClock.now - visionStart).inSeconds
                            )
                        }
                    case .inCloud:
                        // Left un-analysed on purpose; reported to the user
                        // rather than silently dropped.
                        return PageResult(
                            index: index,
                            outcome: .inCloud,
                            imageLoadSeconds: loadSeconds,
                            visionSeconds: 0
                        )
                    case .unavailable:
                        return PageResult(
                            index: index,
                            outcome: .unavailable,
                            imageLoadSeconds: loadSeconds,
                            visionSeconds: 0
                        )
                    }
                }
            }

            // Prime the pool.
            while inFlight < maxConcurrentAnalyses, let next = iterator.next() {
                addTask(next); inFlight += 1
            }

            var freshlyAnalysed = 0
            var pending: [AnalysisCacheStore.Entry] = []
            pending.reserveCapacity(toAnalyse.count)

            while let pageResult = try await group.next() {
                inFlight -= 1
                scanProgress += 1
                reportProgress()

                // Timings are summed here, on the main actor, from values the
                // tasks carried back — no shared mutable counter, no hop.
                metrics.record(ScanMetrics.Phase.imageLoad, seconds: pageResult.imageLoadSeconds)
                if pageResult.visionSeconds > 0 {
                    metrics.record(ScanMetrics.Phase.vision, seconds: pageResult.visionSeconds)
                }
                if scanProgress % memorySampleInterval == 0 { sampleMemory() }

                switch pageResult.outcome {
                case let .analysed(result):
                    let index = pageResult.index
                    enriched[index].featurePrint = result.featurePrint
                    enriched[index].score = result.score
                    enriched[index].sceneTags = result.sceneTags
                    enriched[index].classificationLabels = result.labels
                    freshlyAnalysed += 1
                    metrics.analysedFresh += 1
                    // 3. Collect for a single batched write below — persisting
                    // per photo meant a disk write for every image in the library.
                    let asset = enriched[index]
                    pending.append(
                        .init(
                            id: asset.id,
                            modificationDate: asset.modificationDate,
                            featurePrint: result.featurePrint,
                            score: result.score,
                            sceneTags: result.sceneTags,
                            labels: result.labels
                        )
                    )

                case .inCloud:
                    iCloudSkippedCount += 1
                    metrics.iCloudSkipped += 1

                case .unavailable:
                    metrics.unavailable += 1

                case let .failed(reason):
                    metrics.noteFailure(reason)
                }

                // Refill.
                if let next = iterator.next() {
                    addTask(next); inFlight += 1
                }
            }

            let writeStart = ContinuousClock.now
            try? await cache.storeBatch(pending)
            recordPhase(ScanMetrics.Phase.cacheWrite, since: writeStart)
            return (enriched, freshlyAnalysed)
        }
    }

    // MARK: - Clustering + scoring

    /// Clustering is timed because it's the one step whose cost grows with the
    /// *accumulated* working set rather than per photo — it re-runs periodically
    /// during a progressive scan, so on a large library it's a plausible place
    /// for time to quietly disappear.
    private func buildStacks(from assets: [PhotoAsset]) -> [PhotoStack] {
        let start = ContinuousClock.now
        let clusters = StackBuilder(config: config).cluster(assets)
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let result = ShotScorer(config: config)
            .makeStacks(from: clusters, assetsByID: byID)
            .sorted { $0.reclaimableCount > $1.reclaimableCount }
        recordPhase(ScanMetrics.Phase.clustering, since: start)
        return result
    }
}
