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

/// A page of snapshotted assets plus the source thumbnails' target size.
struct AssetPage: Sendable {
    let assets: [PhotoAsset]
    /// Zero-based index of this page within the overall enumeration.
    let pageIndex: Int
    let isLastPage: Bool
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

    init(pageSize: Int = 200) {
        self.pageSize = pageSize
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
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.includeHiddenAssets = false
            let fetch = PHAsset.fetchAssets(with: .image, options: options)

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
                continuation.yield(AssetPage(assets: page, pageIndex: pageIndex, isLastPage: isLast))
                pageIndex += 1
                start = end
            }
            continuation.finish()
        }
    }

    /// Snapshots the fields we need from a live `PHAsset` into a `Sendable`
    /// value type. Called on the main actor while the asset is valid.
    private static func snapshot(_ asset: PHAsset) -> PhotoAsset {
        PhotoAsset(
            id: asset.localIdentifier,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isFavorite: asset.isFavorite,
            coordinate: asset.location?.coordinate,
            featurePrint: nil,
            score: nil
        )
    }

    // MARK: - Pixel loading (for the analyzer)

    /// Loads a downscaled `CGImage` for analysis by identifier. Re-resolves the
    /// live `PHAsset` here (on the main actor) so no `PHAsset` ever crosses an
    /// actor boundary. Returns `nil` if the asset is gone or can't be decoded.
    func analysisImage(for localIdentifier: String) async -> CGImage? {
        guard let asset = Self.fetchAsset(localIdentifier) else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false      // strictly on-device
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            var didResume = false
            imageManager.requestImage(
                for: asset,
                targetSize: analysisTargetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // requestImage may call back more than once (degraded then full);
                // guard so we resume the continuation exactly once.
                if didResume { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                didResume = true
                continuation.resume(returning: image?.cgImage)
            }
        }
    }

    private static func fetchAsset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    // MARK: - UI thumbnails

    /// Loads a display thumbnail for a photo tile. Delivers the high-quality
    /// image once (the request may fire a degraded preview first, which we
    /// skip). `aspectFill` so tiles crop nicely to a square/rect.
    ///
    /// Unlike analysis, this permits network access so iCloud-only photos still
    /// render in the UI.
    func thumbnail(for localIdentifier: String, targetSize: CGSize) async -> UIImage? {
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
                contentMode: .aspectFill,
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

    // MARK: - Deletion (Phase 2 entry point — kept here for cohesion)

    /// Deletes assets by identifier. **This is the only method that removes
    /// photos, and it is only ever invoked after explicit user confirmation in
    /// the UI.** The system also shows its own confirmation sheet.
    ///
    /// - Returns: `true` if the user confirmed and deletion succeeded.
    @discardableResult
    func deleteAssets(withIdentifiers ids: [String]) async throws -> Bool {
        guard !ids.isEmpty else { return false }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
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
