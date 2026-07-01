//
//  TidyGalleryApp.swift
//  TidyGallery
//
//  Composition root. Builds the SwiftData container and wires the services that
//  the (Phase 2) UI will consume. Kept deliberately thin — no business logic.
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

    /// The scan coordinator the UI observes. Constructed once at launch.
    @State private var coordinator: LibraryScanCoordinator

    init() {
        // 1. SwiftData container for the on-device analysis cache.
        let container: ModelContainer
        do {
            container = try ModelContainer(for: CachedAnalysis.self)
        } catch {
            // A cache we can't open is not fatal to the concept, but it is fatal
            // to performance guarantees — fail loudly in development.
            fatalError("Failed to create ModelContainer: \(error)")
        }
        self.modelContainer = container

        // 2. Wire services. The cache store is a ModelActor bound to the
        //    container's configuration.
        let cache = AnalysisCacheStore(modelContainer: container)
        let coordinator = LibraryScanCoordinator(
            library: PhotoLibraryService(),
            analyzer: ImageAnalyzer(),
            cache: cache
        )
        _coordinator = State(initialValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            // Phase 2 replaces this with the stacks UI. For now, a minimal
            // driver so the pipeline is runnable end-to-end.
            ScanRootView(coordinator: coordinator)
        }
        .modelContainer(modelContainer)
    }
}

/// Minimal placeholder screen that runs a scan and reports progress. Phase 2
/// swaps this for the real stacks gallery.
private struct ScanRootView: View {
    let coordinator: LibraryScanCoordinator

    var body: some View {
        VStack(spacing: 16) {
            switch coordinator.phase {
            case .idle:
                Button("Scan Library") { Task { await coordinator.scan() } }
            case .requestingAccess:
                ProgressView("Requesting access…")
            case let .scanning(analysed, _):
                ProgressView("Analysed \(analysed) photos…")
            case .clustering:
                ProgressView("Grouping similar photos…")
            case let .finished(count):
                Text("Found \(count) stacks to review.")
            case .accessDenied:
                Text("Photo access is required. Enable it in Settings.")
            case let .failed(message):
                Text("Scan failed: \(message)")
            }
        }
        .padding()
    }
}
