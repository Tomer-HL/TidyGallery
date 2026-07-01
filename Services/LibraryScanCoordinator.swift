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

    // MARK: Collaborators

    private let library: PhotoLibraryService
    private let analyzer: ImageAnalyzer
    private let cache: AnalysisCacheStore
    private let config: AnalysisConfiguration

    /// Bounds how many images are decoded + analysed at once. Tuned low to keep
    /// peak memory and thermals in check on large libraries; raise cautiously.
    private let maxConcurrentAnalyses: Int

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
        let stacks = buildStacks(from: enriched)
        self.stacks = stacks
        phase = .finished(stackCount: stacks.count)
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
