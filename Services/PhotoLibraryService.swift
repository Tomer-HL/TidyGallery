//
//  PhotoLibraryService.swift
//  TidyGallery
//
//  Owns every interaction with the Photos framework: authorization, memory-safe
//  batch enumeration of a 20,000+ photo library, on-demand thumbnail loading,
//  and (Phase 2) deletion. Isolated to the main actor because `PHPhotoLibrary`
//  and change notifications are delivered there; heavy pixel work is handed off
//  to the `ImageAnalyzer` actor.
//

import Foundation
import Photos
import UIKit

/// Result of requesting photo access, mapping `PHAuthorizationStatus` to a
/// product-meaningful state.
enum PhotoAccess: Sendable, Equatable {
    case authorized      // full library
    case limited         // user picked a subset — degrade gracefully
    case denied
    case restricted
    case notDetermined
}

/// Outcome of trying to load an image for analysis.
///
/// Declared at file scope, like `PhotoAccess` and `AssetPage`: nesting it inside
/// the `@MainActor` service would make it main-actor isolated too, and it has to
/// be matched inside the nonisolated analysis task group.
enum AnalysisImage: Sendable {
    case image(CGImage)
    /// The asset lives only in iCloud and network access wasn't permitted.
    /// Deliberately distinct from a plain failure so the user can be told, and
    /// offered the choice to download.
    case inCloud
    case unavailable
}

/// A page of snapshotted assets plus the source thumbnails' target size.
struct AssetPage: Sendable {
    let assets: [PhotoAsset]
    /// Zero-based index of this page within the overall enumeration.
    let pageIndex: Int
    let isLastPage: Bool
    /// Total assets in the whole enumeration, so progress can be reported as
    /// "x of y" from the very first page rather than counting up blindly.
    let totalCount: Int
}

@MainActor
final class PhotoLibraryService {

    /// How many assets we snapshot per page. Snapshots are tiny value types, so
    /// this bounds only the working set handed to the analyzer at a time.
    private let pageSize: Int

    /// Target pixel size requested for analysis thumbnails. Vision's feature
    /// print and face landmarks don't need full resolution; ~512px keeps memory
    /// and decode cost low while preserving enough detail for blur/faces.
    private let analysisTargetSize = CGSize(width: 512, height: 512)

    private let imageManager = PHCachingImageManager()

    /// How much of the library to consider. Every fetch below honours this, so
    /// narrowing the window genuinely reduces the work rather than just
    /// reordering it.
    var scope: ScanScope = .allTime

    init(pageSize: Int = 200) {
        self.pageSize = pageSize
    }

    /// Fetch options with the scope's date window applied.
    ///
    /// - Parameter newestFirst: analysis walks newest-first so the photos people
    ///   most want to clean surface earliest in a progressive scan.
    private func scopedOptions(newestFirst: Bool = true, sorted: Bool = true) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        if sorted {
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !newestFirst)]
        }
        if let cutoff = scope.cutoffDate() {
            options.predicate = NSPredicate(format: "creationDate >= %@", cutoff as NSDate)
        }
        return options
    }

    // MARK: - Authorization

    /// Requests read/write access and returns the resulting state. Safe to call
    /// repeatedly; returns immediately if already determined.
    func requestAccess() async -> PhotoAccess {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
        return Self.map(status)
    }

    var currentAccess: PhotoAccess {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .authorized: .authorized
        case .limited:    .limited
        case .denied:     .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    // MARK: - Memory-safe enumeration

    /// Streams the user's photos as pages of lightweight snapshots.
    ///
    /// Memory strategy for large libraries:
    /// - We hold a single `PHFetchResult`, which is lazy — it does NOT
    ///   materialise 20k `PHAsset` objects; it faults them in on access.
    /// - We enumerate in windows of `pageSize`, snapshot each asset into a
    ///   `Sendable` `PhotoAsset`, and yield the page. The heavyweight
    ///   `PHAsset`s in the window go out of scope immediately.
    /// - The caller (scan coordinator) analyses one page, persists results,
    ///   then requests the next — so peak memory is O(pageSize), not O(library).
    ///
    /// Only still images are enumerated (no videos) for Phase 1.
    func assetPages() -> AsyncStream<AssetPage> {
        AsyncStream { continuation in
            // Newest first: in a progressive scan the most recent photos are the
            // ones the user wants to act on soonest.
            let fetch = PHAsset.fetchAssets(with: .image, options: self.scopedOptions())

            let total = fetch.count
            guard total > 0 else {
                continuation.finish()
                return
            }

            var pageIndex = 0
            var start = 0
            while start < total {
                let end = min(start + pageSize, total)
                var page: [PhotoAsset] = []
                page.reserveCapacity(end - start)

                // `enumerateObjects(at:)` faults assets in lazily for just this
                // window; each `phAsset` is released as the loop advances.
                let indexSet = IndexSet(integersIn: start..<end)
                fetch.enumerateObjects(at: indexSet, options: []) { phAsset, _, _ in
                    page.append(Self.snapshot(phAsset))
                }

                let isLast = end >= total
                continuation.yield(
                    AssetPage(
                        assets: page,
                        pageIndex: pageIndex,
                        isLastPage: isLast,
                        totalCount: total
                    )
                )
                pageIndex += 1
                start = end
            }
            continuation.finish()
        }
    }

    /// Snapshots specific assets by identifier (still images only) — used to
    /// re-analyse just the delta when the library changes.
    func snapshots(for identifiers: [String]) -> [PhotoAsset] {
        guard !identifiers.isEmpty else { return [] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var result: [PhotoAsset] = []
        fetched.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image {
                result.append(Self.snapshot(asset))
            }
        }
        return result
    }

    /// Fetches all screenshots (newest first) from the system "Screenshots"
    /// smart album, as `Sendable` snapshots.
    func fetchScreenshots() -> [PhotoAsset] {
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumScreenshots,
            options: nil
        )
        guard let album = albums.firstObject else { return [] }

        let assets = PHAsset.fetchAssets(in: album, options: scopedOptions())

        var result: [PhotoAsset] = []
        result.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            result.append(Self.snapshot(asset))
        }
        return result
    }

    /// All videos in the library, newest first, as `Sendable` snapshots (each
    /// carrying its `duration`). Ordering by real file size is done by the UI
    /// once sizes have been measured, since size isn't a fetchable sort key.
    func fetchVideos() -> [PhotoAsset] {
        let assets = PHAsset.fetchAssets(with: .video, options: scopedOptions())

        var result: [PhotoAsset] = []
        result.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            result.append(Self.snapshot(asset))
        }
        return result
    }

    /// Videos **and** the subset that are screen recordings, in a single pass.
    ///
    /// Fetching these separately meant enumerating every video twice and doing
    /// the (not cheap) `PHAssetResource` lookup for each one again. Callers that
    /// need both should use this.
    func fetchVideosAndScreenRecordings() -> (videos: [PhotoAsset], recordings: [PhotoAsset]) {
        let assets = PHAsset.fetchAssets(with: .video, options: scopedOptions())

        var videos: [PhotoAsset] = []
        var recordings: [PhotoAsset] = []
        videos.reserveCapacity(assets.count)

        assets.enumerateObjects { asset, _, _ in
            let snapshot = Self.snapshot(asset)
            videos.append(snapshot)
            let isScreenRecording = PHAssetResource.assetResources(for: asset)
                .contains { $0.originalFilename.lowercased().hasPrefix("rpreplay") }
            if isScreenRecording { recordings.append(snapshot) }
        }
        return (videos, recordings)
    }

    /// Screen recordings, detected heuristically. iOS exposes no public
    /// smart-album subtype for them, so we match ReplayKit's filename signature:
    /// Control-Center recordings are written as `RPReplay_Final…​.mp4` /
    /// `RPReplay_Original…`, so an `RPReplay` prefix on *any* of the asset's
    /// resources is the reliable on-device signal. Everything stays on-device;
    /// if nothing matches we return an empty list. (A recording the user
    /// manually renamed won't be detected — acceptable: it just won't appear
    /// here, never a false deletion.)
    func fetchScreenRecordings() -> [PhotoAsset] {
        let assets = PHAsset.fetchAssets(with: .video, options: scopedOptions())

        var result: [PhotoAsset] = []
        assets.enumerateObjects { asset, _, _ in
            let isScreenRecording = PHAssetResource.assetResources(for: asset)
                .contains { $0.originalFilename.lowercased().hasPrefix("rpreplay") }
            if isScreenRecording {
                result.append(Self.snapshot(asset))
            }
        }
        return result
    }

    /// Candidate set for the "Big files" category: every Live Photo plus the
    /// highest-resolution stills (up to `stillLimit`). Reading real on-disk size
    /// for a whole library is expensive, so we bound the pool cheaply here —
    /// resolution is a good proxy for which stills are large — and let the UI
    /// measure exact sizes for just this set via `fileSizes(for:)` and sort.
    ///
    /// Note: `PHFetchOptions` only supports sorting by creation/modification
    /// date, so we do NOT sort the fetch by resolution (that would raise at
    /// runtime). We snapshot into value types — releasing each `PHAsset` as the
    /// lazy enumeration advances, so peak memory stays bounded — then rank the
    /// (small) `PhotoAsset` snapshots by pixel area in memory.
    func fetchLargeFileCandidates(stillLimit: Int) -> [PhotoAsset] {
        let assets = PHAsset.fetchAssets(with: .image, options: scopedOptions(sorted: false))

        var livePhotos: [PhotoAsset] = []
        var stills: [PhotoAsset] = []
        assets.enumerateObjects { asset, _, _ in
            let snapshot = Self.snapshot(asset)
            if asset.mediaSubtypes.contains(.photoLive) {
                livePhotos.append(snapshot)                  // Live Photos carry a video → often large
            } else {
                stills.append(snapshot)
            }
        }

        // Highest pixel area first (a cheap proxy for file size), each capped so
        // the caller's exact-size measurement stays bounded on huge libraries.
        func topByArea(_ list: [PhotoAsset]) -> [PhotoAsset] {
            list.sorted { ($0.pixelWidth * $0.pixelHeight) > ($1.pixelWidth * $1.pixelHeight) }
                .prefix(stillLimit)
                .map { $0 }
        }
        return topByArea(livePhotos) + topByArea(stills)
    }

    /// Snapshots the fields we need from a live `PHAsset` into a `Sendable`
    /// value type. Called on the main actor while the asset is valid.
    private static func snapshot(_ asset: PHAsset) -> PhotoAsset {
        let kind: PhotoAsset.MediaKind = switch asset.mediaType {
        case .image: .image
        case .video: .video
        default: .unknown
        }
        return PhotoAsset(
            id: asset.localIdentifier,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isFavorite: asset.isFavorite,
            coordinate: asset.location?.coordinate,
            mediaType: kind,
            duration: asset.duration,
            featurePrint: nil,
            score: nil
        )
    }

    // MARK: - Pixel loading (for the analyzer)

    /// Loads a downscaled `CGImage` for analysis by identifier. Re-resolves the
    /// live `PHAsset` here (on the main actor) so no `PHAsset` ever crosses an
    /// actor boundary.
    ///
    /// iCloud handling matters for correctness, not just completeness. With
    /// "Optimize iPhone Storage" many assets exist locally only as a small
    /// degraded thumbnail. Analysing *that* would be actively wrong: Laplacian
    /// sharpness measured on a downscaled thumbnail is artificially low (a sharp
    /// photo would be reported blurry) and its feature print wouldn't match the
    /// full-resolution one, breaking duplicate detection. So a degraded image is
    /// never accepted — we report `.inCloud` and let the caller decide.
    func analysisImage(
        for localIdentifier: String,
        allowNetwork: Bool = false
    ) async -> AnalysisImage {
        guard let asset = Self.fetchAsset(localIdentifier) else { return .unavailable }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            var didResume = false
            func finish(_ result: AnalysisImage) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: result)
            }

            imageManager.requestImage(
                for: asset,
                targetSize: analysisTargetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false

                if isDegraded {
                    // Only a placeholder so far. If the real one is in iCloud and
                    // we may not fetch it, no better callback is coming — resolve
                    // now rather than waiting forever.
                    if isInCloud && !allowNetwork { finish(.inCloud) }
                    return
                }

                if let cgImage = image?.cgImage {
                    finish(.image(cgImage))
                } else if isInCloud {
                    finish(.inCloud)
                } else {
                    finish(.unavailable)
                }
            }
        }
    }

    private static func fetchAsset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    // MARK: - UI thumbnails

    /// Square-cropped thumbnail for a filmstrip tile.
    ///
    /// Unlike analysis, UI image requests permit network access so iCloud-only
    /// photos still render.
    func thumbnail(for localIdentifier: String, targetSize: CGSize) async -> UIImage? {
        await requestUIImage(localIdentifier, targetSize: targetSize, contentMode: .aspectFill)
    }

    /// Large, aspect-fit image for the full-screen preview (whole photo visible).
    func previewImage(for localIdentifier: String, targetSize: CGSize) async -> UIImage? {
        await requestUIImage(localIdentifier, targetSize: targetSize, contentMode: .aspectFit)
    }

    private func requestUIImage(
        _ localIdentifier: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) async -> UIImage? {
        guard let asset = Self.fetchAsset(localIdentifier) else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            var didResume = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                if didResume { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }        // wait for the full-quality pass
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - On-disk sizes

    /// Total on-disk byte size for each asset id, fetched in one query.
    ///
    /// Sums every `PHAssetResource` for the asset (original + any edited render),
    /// which is what deleting it actually frees. `fileSize` isn't a public
    /// property, so we read it via KVC — the long-standing, widely-used approach;
    /// assets whose size can't be read are simply omitted.
    func fileSizes(for identifiers: [String]) -> [String: Int64] {
        guard !identifiers.isEmpty else { return [:] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)

        var sizes: [String: Int64] = [:]
        fetched.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            var total: Int64 = 0
            var found = false
            for resource in resources {
                if let number = resource.value(forKey: "fileSize") as? NSNumber {
                    total += number.int64Value
                    found = true
                }
            }
            if found { sizes[asset.localIdentifier] = total }
        }
        return sizes
    }

    /// Off-main variant of `fileSizes(for:)` for large id sets.
    ///
    /// The dashboard summary measures every duplicate extra, screenshot, video,
    /// big file and recording, which can be thousands of assets — far too many to
    /// walk on the main actor without a visible hitch. The Photos read APIs used
    /// here are thread-safe, so this runs off the main actor and the coordinator
    /// awaits it from a background task.
    nonisolated func assetFileSizes(for identifiers: [String]) async -> [String: Int64] {
        guard !identifiers.isEmpty else { return [:] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)

        var sizes: [String: Int64] = [:]
        fetched.enumerateObjects { asset, _, _ in
            var total: Int64 = 0
            var found = false
            for resource in PHAssetResource.assetResources(for: asset) {
                if let number = resource.value(forKey: "fileSize") as? NSNumber {
                    total += number.int64Value
                    found = true
                }
            }
            if found { sizes[asset.localIdentifier] = total }
        }
        return sizes
    }

    /// On-disk size of **every** asset in the library, keyed by local identifier.
    ///
    /// One pass serves two jobs: summing it gives the dashboard's "of X used"
    /// figure, and the per-asset sizes are the cheap pre-filter that
    /// `ExactDuplicateFinder` uses to find identical copies.
    ///
    /// `nonisolated` on purpose: this does a `fileSize` resource lookup for every
    /// asset, which is heavy on a large library. The Photos read APIs used here
    /// are thread-safe, so we run it off the main actor (kicked off in the
    /// background once per scan) to avoid blocking the UI. It never mutates
    /// anything and touches no main-actor state.
    nonisolated func libraryFileSizes() async -> [String: Int64] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        let assets = PHAsset.fetchAssets(with: options)

        var sizes: [String: Int64] = [:]
        assets.enumerateObjects { asset, _, _ in
            var total: Int64 = 0
            var found = false
            for resource in PHAssetResource.assetResources(for: asset) {
                if let number = resource.value(forKey: "fileSize") as? NSNumber {
                    total += number.int64Value
                    found = true
                }
            }
            if found { sizes[asset.localIdentifier] = total }
        }
        return sizes
    }

    // MARK: - Deletion (Phase 2 entry point — kept here for cohesion)

    // MARK: - Albums

    /// Creates a new Photos album containing the given assets.
    ///
    /// This only *references* existing assets in a new collection — nothing is
    /// copied, nothing is removed, and the originals stay exactly where they are.
    ///
    /// `nonisolated` for the same reason as `deleteAssets`: `PHPhotoLibrary`
    /// runs the change block and fires its completion on its own private queue,
    /// and awaiting that from the main actor makes the Swift 6 runtime's
    /// isolation check trap. Assets are fetched inside the block so no
    /// non-`Sendable` fetch result crosses the boundary.
    nonisolated func createAlbum(named title: String, withAssetIDs ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            // Note: this returns a NON-optional in Swift, so no `guard let`.
            let request = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: title)
            request.addAssets(assets)
        }
    }

    /// Deletes assets by identifier. **This is the only method that removes
    /// photos, and it is only ever invoked after explicit user confirmation in
    /// the UI.** The system also shows its own confirmation sheet.
    ///
    /// Concurrency: this method is deliberately `nonisolated`. `PHPhotoLibrary`
    /// runs the change block *and* fires its completion on its own private
    /// background queue (`com.apple.PHPhotoLibrary.changes`). If this awaited
    /// from the main actor, the Swift 6 runtime's isolation check would assert
    /// it's on the main queue when the completion lands on the Photos queue and
    /// **trap** (`EXC_BREAKPOINT` / `dispatch_assert_queue_fail`). Running the
    /// call off any actor removes that requirement; the caller re-hops to
    /// `@MainActor` normally when this async method returns. The assets are also
    /// fetched *inside* the change block so no non-`Sendable` `PHFetchResult`
    /// is captured across the `@Sendable` boundary.
    ///
    /// - Returns: `true` if the user confirmed and deletion succeeded.
    @discardableResult
    nonisolated func deleteAssets(withIdentifiers ids: [String]) async throws -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return true
        } catch {
            // A user cancelling the system confirmation surfaces as an error;
            // treat that as a non-fatal "not confirmed" rather than a failure.
            if (error as NSError).code == 3072 { return false } // user cancelled
            throw error
        }
    }
}
