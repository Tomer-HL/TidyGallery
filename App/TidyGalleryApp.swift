//
//  TidyGalleryApp.swift
//  TidyGallery
//
//  Composition root. Builds the SwiftData container, wires the services, and
//  injects the photo library into the environment so any view can load
//  thumbnails. Kept deliberately thin — no business logic.
//
//  Info.plist requirement:
//    NSPhotoLibraryUsageDescription  — required to request photo access.
//    NSPhotoLibraryAddUsageDescription is NOT needed (we delete, not add).
//

import SwiftUI
import SwiftData
import Foundation

@main
struct TidyGalleryApp: App {

    /// SwiftData container for the disposable analysis cache.
    let modelContainer: ModelContainer

    /// SwiftData container for the user's decisions, in a **separate store
    /// file** from the cache. See `makeIgnoreContainer()`.
    let ignoreContainer: ModelContainer

    /// Photo library service — shared by the scan pipeline and the UI thumbnails.
    let library: PhotoLibraryService

    /// The scan coordinator the UI observes. Constructed once at launch.
    @State private var coordinator: LibraryScanCoordinator

    init() {
        // 1. Two containers, on purpose — see the notes on each factory below.
        let container = Self.makeCacheContainer()
        self.modelContainer = container

        let ignoreContainer = Self.makeIgnoreContainer()
        self.ignoreContainer = ignoreContainer

        // 2. Wire services. One PhotoLibraryService is shared everywhere.
        let library = PhotoLibraryService()
        self.library = library

        let cache = AnalysisCacheStore(modelContainer: container)
        let ignoreList = IgnoreListStore(modelContainer: ignoreContainer)
        Self.importLegacyIgnoreList(from: container, into: ignoreContainer)

        // Detection settings the user has tuned in-app (defaults on first run).
        let tuning = TuningStore.load()
        let coordinator = LibraryScanCoordinator(
            library: library,
            analyzer: ImageAnalyzer(config: tuning.applied()),
            cache: cache,
            ignoreList: ignoreList,
            tuning: tuning
        )
        _coordinator = State(initialValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .environment(\.photoLibrary, library)
        }
        .modelContainer(modelContainer)
    }

    // MARK: - Resilient cache container

    /// Builds the SwiftData container for the analysis cache. The cache is
    /// purely a performance optimisation and fully disposable, so a schema
    /// migration failure must never brick launch: if the on-disk store can't be
    /// opened (e.g. an incompatible older schema), we wipe it and retry, and as a
    /// last resort fall back to an in-memory cache. Either way the app still
    /// works — it just re-analyses.
    private static func makeCacheContainer() -> ModelContainer {
        // `IgnoredAsset` is still in this schema so the legacy rows in an
        // existing `default.store` remain readable for the one-time import
        // below. Nothing writes them here any more.
        let schema = Schema([CachedAnalysis.self, IgnoredAsset.self])

        if let container = try? ModelContainer(for: schema) {
            return container
        }

        // Wipe the default on-disk store and retry.
        let dir = URL.applicationSupportDirectory
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        if let container = try? ModelContainer(for: schema) {
            return container
        }

        // Last resort: ephemeral in-memory cache (not persisted between launches).
        let inMemory = ModelConfiguration(isStoredInMemoryOnly: true)
        // Safe to force-try: an in-memory store has nothing to migrate or open.
        return try! ModelContainer(for: schema, configurations: inMemory)
    }

    // MARK: - The user's decisions

    /// Builds the container for the ignore list, in **its own store file**.
    ///
    /// The two stores hold categorically different things and must not share a
    /// fate. The analysis cache is disposable — it is wiped wholesale on every
    /// `schemaVersion` bump, and `makeCacheContainer()` deletes the whole file
    /// to recover from a migration failure. The ignore list is the opposite: it
    /// is the user's own decisions, and there is no way to reconstruct it.
    ///
    /// Keeping `IgnoredAsset` in a separate *entity* was never enough, because
    /// entities in one SwiftData store share one file — so `default.store` being
    /// deleted took every "don't suggest this again" with it. Separating them
    /// here is what actually delivers the guarantee the design intended.
    ///
    /// Note the deliberate asymmetry in the failure path: the cache degrades to
    /// in-memory happily, because losing it costs a re-scan. This one only ever
    /// falls back after trying hard not to, and never wipes the file to recover.
    private static func makeIgnoreContainer() -> ModelContainer {
        let schema = Schema([IgnoredAsset.self])
        let configuration = ModelConfiguration(
            "IgnoreList",
            schema: schema,
            url: URL.applicationSupportDirectory.appendingPathComponent("IgnoreList.store")
        )

        if let container = try? ModelContainer(for: schema, configurations: configuration) {
            return container
        }

        // Deliberately NOT deleting the store to recover. If it can't be opened,
        // an in-memory list means this session's decisions don't persist — bad,
        // but recoverable next launch. Wiping the file would destroy them for
        // good, which is exactly the outcome this whole arrangement exists to
        // prevent.
        let inMemory = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: inMemory)
    }

    /// One-time move of ignore rows written by older builds into the cache
    /// store, before the two were separated.
    ///
    /// Best-effort by design: this runs on every launch, and if anything about
    /// it fails the app carries on. It only ever *adds*, and only when the new
    /// store is empty, so it can't clobber newer decisions or duplicate rows on
    /// a second run.
    private static func importLegacyIgnoreList(
        from legacy: ModelContainer,
        into destination: ModelContainer
    ) {
        let destinationContext = ModelContext(destination)
        let existing = (try? destinationContext.fetchCount(FetchDescriptor<IgnoredAsset>())) ?? 0
        guard existing == 0 else { return }

        let legacyContext = ModelContext(legacy)
        guard let rows = try? legacyContext.fetch(FetchDescriptor<IgnoredAsset>()), !rows.isEmpty else {
            return
        }

        for row in rows {
            destinationContext.insert(IgnoredAsset(localIdentifier: row.localIdentifier))
        }
        try? destinationContext.save()
    }
}
