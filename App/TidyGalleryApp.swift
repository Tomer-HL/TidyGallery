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
        let container: ModelContainer
        do {
            container = try ModelContainer(for: CachedAnalysis.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
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
}
