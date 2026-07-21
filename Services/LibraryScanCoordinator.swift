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

    // MARK: Collaborators

    private let library: PhotoLibraryService
    private let analyzer: ImageAnalyzer
    private let cache: AnalysisCacheStore
    private let config: AnalysisConfiguration

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
        config: AnalysisConfiguration = .default,
        maxConcurrentAnalyses: Int = 4
    ) {
        self.library = library
        self.analyzer = analyzer
        self.cache = cache
        self.config = config
        self.maxConcurrentAnalyses = maxConcurrentAnalyses
    }

    // MARK: - Public entry point

    /// Runs a full scan and publishes the resulting stacks. Safe to call again;
    /// cached assets are skipped so subsequent runs are fast.
    func scan() async {
        phase = .requestingAccess
        let access = await library.requestAccess()
        switch access {
        case .denied, .restricted:
            phase = .accessDenied
            return
        case .notDetermined:
            phase = .failed("Photo access was not granted.")
            return
        case .authorized, .limited:
            break   // `.limited` still works; we scan whatever we're allowed.
        }

        var enriched: [PhotoAsset] = []
        var analysedCount = 0

        do {
            for await page in library.assetPages() {
                let (pageAssets, newlyAnalysed) = try await process(page: page)
                enriched.append(contentsOf: pageAssets)
                analysedCount += newlyAnalysed
                phase = .scanning(analysed: enriched.count, total: enriched.count) // running tally
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // Cluster + score.
        phase = .clustering
        analysedAssets = enriched
        let stacks = buildStacks(from: enriched)
        self.stacks = stacks
        refreshCategories()
        phase = .finished(stackCount: stacks.count)

        startObserving()
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
                    asset.featurePrint = hit.0
                    asset.score = hit.1
                } else if let cgImage = await library.analysisImage(for: asset.id),
                          let result = try? await analyzer.analyze(image: cgImage, isFavorite: asset.isFavorite) {
                    asset.featurePrint = result.featurePrint
                    asset.score = result.score
                    try? await cache.store(
                        id: asset.id,
                        modificationDate: asset.modificationDate,
                        featurePrint: result.featurePrint,
                        score: result.score
                    )
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
    private func refreshCategories() {
        screenshots = library.fetchScreenshots()
        largeVideos = library.fetchVideos()
        screenRecordings = library.fetchScreenRecordings()
        bigFileCandidates = computeBigFiles()
        blurryPhotos = deriveBlurrySingles()
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
        let eligible = analysedAssets.filter { asset in
            asset.mediaType == .image
                && !asset.isFavorite
                && !grouped.contains(asset.id)
                && asset.score != nil
        }
        guard !eligible.isEmpty else { return [] }

        // Relative floor: the sharpness value at the configured low percentile.
        let sortedSharpness = eligible.compactMap { $0.score?.sharpness }.sorted()
        let percentileIndex = Int(Double(sortedSharpness.count - 1) * config.blurryPercentile)
        let percentileFloor = sortedSharpness[max(0, percentileIndex)]

        // Flag only photos below BOTH the relative floor and the absolute ceiling.
        let cutoff = min(percentileFloor, config.blurrySinglesSharpnessCeiling)
        return eligible
            .filter { ($0.score?.sharpness ?? 1) <= cutoff }
            .sorted { ($0.score?.sharpness ?? 0) < ($1.score?.sharpness ?? 0) }
            .prefix(config.blurryMaxCount)
            .map { $0 }
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
        pruneStacks(removing: removed)
        phase = .finished(stackCount: stacks.count)
    }

    /// Drop deleted assets from existing stacks without re-clustering. A stack
    /// that falls to a single photo is removed (no longer a cleanup group); if
    /// the best shot was deleted, the top surviving ranked photo inherits it.
    private func pruneStacks(removing removed: Set<PhotoAsset.ID>) {
        stacks = stacks.compactMap { stack in
            let remaining = stack.assets.filter { !removed.contains($0.id) }
            guard remaining.count > 1 else { return nil }
            let ranked = stack.rankedAssetIDs.filter { !removed.contains($0) }
            let best = removed.contains(stack.bestShotID) ? (ranked.first ?? remaining[0].id) : stack.bestShotID
            return PhotoStack(
                id: stack.id,
                assets: remaining,
                bestShotID: best,
                rankedAssetIDs: ranked,
                assetsPreselectedForDeletion: stack.assetsPreselectedForDeletion.subtracting(removed)
            )
        }
    }

    // MARK: - Per-page processing

    /// Analyses the cache-misses on a page and returns the enriched assets plus
    /// how many were freshly analysed (for progress).
    private func process(page: AssetPage) async throws -> (assets: [PhotoAsset], newlyAnalysed: Int) {
        // 1. Batch cache lookup.
        let keys = page.assets.map { (id: $0.id, modificationDate: $0.modificationDate) }
        let cached = try await cache.freshAnalysis(for: keys)

        var enriched = page.assets
        var toAnalyse: [Int] = []   // indices into `enriched`

        for i in enriched.indices {
            if let hit = cached[enriched[i].id] {
                enriched[i].featurePrint = hit.0
                enriched[i].score = hit.1
            } else {
                toAnalyse.append(i)
            }
        }

        guard !toAnalyse.isEmpty else { return (enriched, 0) }

        // 2. Analyse misses with bounded concurrency.
        return try await withThrowingTaskGroup(of: (Int, AnalyzedImage?).self) { group in
            var inFlight = 0
            var iterator = toAnalyse.makeIterator()

            func addTask(_ index: Int) {
                let asset = enriched[index]
                group.addTask { [library, analyzer] in
                    guard let cgImage = await library.analysisImage(for: asset.id) else {
                        return (index, nil)
                    }
                    let result = try await analyzer.analyze(image: cgImage, isFavorite: asset.isFavorite)
                    return (index, result)
                }
            }

            // Prime the pool.
            while inFlight < maxConcurrentAnalyses, let next = iterator.next() {
                addTask(next); inFlight += 1
            }

            var freshlyAnalysed = 0
            while let (index, result) = try await group.next() {
                inFlight -= 1
                if let result {
                    enriched[index].featurePrint = result.featurePrint
                    enriched[index].score = result.score
                    freshlyAnalysed += 1
                    // 3. Persist (fire-and-forget within the group's lifetime).
                    let asset = enriched[index]
                    try? await cache.store(
                        id: asset.id,
                        modificationDate: asset.modificationDate,
                        featurePrint: result.featurePrint,
                        score: result.score
                    )
                }
                // Refill.
                if let next = iterator.next() {
                    addTask(next); inFlight += 1
                }
            }
            return (enriched, freshlyAnalysed)
        }
    }

    // MARK: - Clustering + scoring

    private func buildStacks(from assets: [PhotoAsset]) -> [PhotoStack] {
        let clusters = StackBuilder(config: config).cluster(assets)
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return ShotScorer(config: config)
            .makeStacks(from: clusters, assetsByID: byID)
            .sorted { $0.reclaimableCount > $1.reclaimableCount }
    }
}
