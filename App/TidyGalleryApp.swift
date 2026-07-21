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

    /// Shared SwiftData container holding the analysis cache.
    let modelContainer: ModelContainer

    /// Photo library service — shared by the scan pipeline and the UI thumbnails.
    let library: PhotoLibraryService

    /// The scan coordinator the UI observes. Constructed once at launch.
    @State private var coordinator: LibraryScanCoordinator

    init() {
        // 1. SwiftData container for the on-device analysis cache.
        let container = Self.makeCacheContainer()
        self.modelContainer = container

        // 2. Wire services. One PhotoLibraryService is shared everywhere.
        let library = PhotoLibraryService()
        self.library = library

        let cache = AnalysisCacheStore(modelContainer: container)
        let coordinator = LibraryScanCoordinator(
            library: library,
            analyzer: ImageAnalyzer(),
            cache: cache
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
        let schema = Schema([CachedAnalysis.self])

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
}
