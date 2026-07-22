//
//  PhotoLibraryService.swift
//  TidyGallery
//
//  Owns every interaction with the Photos framework: authorization, memory-safe
//  batch enumeration of a 20,000+ photo library, on-demand thumbnail loading,
//  and deletion.
//
//  Concurrency: why this is NOT on the main actor
//  ---------------------------------------------
//  It used to be, on the reasoning that `PHPhotoLibrary` and its change
//  notifications are delivered there. Measurement on a real device showed what
//  that actually cost:
//
//    * The "instant" metadata pass took 607 ms for 110 photos and 1,022 ms for
//      228 — about 4.5 ms per asset, all of it blocking the main thread. That
//      extrapolates to roughly 90 seconds of frozen UI on a 20,000-photo
//      library, before the home screen can draw anything. The whole point of
//      that pass is that it appears immediately.
//
//    * Analysis achieved only 2–3× parallelism from a 4-wide pool, because every
//      worker had to hop to the main actor for `analysisImage`, which also runs
//      a `PHAsset.fetchAssets` per photo. The main actor was the bottleneck, not
//      the CPU.
//
//  The Photos *read* APIs used here are thread-safe — this file already relied
//  on that for `libraryFileSizes`, which has been `nonisolated` since it was
//  written. So the whole service is now `Sendable` with no isolation, and the
//  main actor is left free to draw.
//
//  Consequences, deliberately accepted:
//    * `scope` is no longer mutable state on the service. It's passed to each
//      fetch, which is why every method that filters by date takes it. Shared
//      mutable state is what made this hard to move off the main actor.
//    * `PHAsset` still never crosses into the analyzer: assets are snapshotted
//      into `Sendable` value types at the boundary, exactly as before.
//    * The heavy enumerations are `async` even though they do no awaiting.
//      That is load-bearing, not decoration: a *nonisolated sync* function
//      called from a `@MainActor` context still runs on the main actor, and so
//      does the body of a `Task {}` or `async let` started there. Only a
//      nonisolated ASYNC function is guaranteed to run on the cooperative pool
//      (SE-0338). Dropping `async` from one of these would silently put it
//      back on the main thread with no diagnostic.
//    * `snapshots(for:)` is deliberately left synchronous: it is only ever
//      called with the ignore list or a change delta, both small and bounded.
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
enum AnalysisImage: Sendable {
    case image(CGImage)
    /// The asset lives only in iCloud and network access wasn't permitted.
    /// Deliberately distinct from a plain failure so the user can be told, and
    /// offered the choice to download.
    case inCloud
    case unavailable
}

/// A page of snapshotted assets.
struct AssetPage: Sendable {
    let assets: [PhotoAsset]
    /// Zero-based index of this page within the overall enumeration.
    let pageIndex: Int
    let isLastPage: Bool
    /// Total assets in the whole enumeration, so progress can be reported as
    /// "x of y" from the very first page rather than counting up blindly.
    let totalCount: Int
}

/// `@unchecked Sendable`, not plain `Sendable`, and the difference is not
/// cosmetic. Every stored property here is an immutable `let`, but
/// `PHCachingImageManager` is not itself `Sendable`, so the compiler cannot
/// verify the conformance no matter how the property is annotated
/// (`nonisolated(unsafe)` waives *isolation* checking on a property; it does not
/// waive a type's `Sendable` conformance requirements). What makes this safe is
/// a fact the compiler has no way to know: `PHImageManager` and its caching
/// subclass are documented as usable from any thread. `@unchecked` is the honest
/// way to say "I checked, and here is why".
final class PhotoLibraryService: @unchecked Sendable {

    /// How many assets we snapshot per page. Snapshots are tiny value types, so
    /// this bounds only the working set handed to the analyzer at a time.
    private let pageSize: Int

    private let imageManager = PHCachingImageManager()

    init(pageSize: Int = 200) {
        self.pageSize = pageSize
    }

    /// Fetch options with a scope's date window applied.
    ///
    /// - Parameter newestFirst: analysis walks newest-first so the photos people
    ///   most want to clean surface earliest in a progressive scan.
    private static func options(
        scope: ScanScope,
        newestFirst: Bool = true,
        sorted: Bool = true
    ) -> PHFetchOptions {
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
    ///
    /// Production runs in a detached task, which matters for two reasons. An
    /// `AsyncStream`'s builder closure runs synchronously on the caller's
    /// executor, so this used to enumerate and snapshot the *entire* library on
    /// the main actor before the consumer saw a single page — an unbounded
    /// stall, and it defeated the paging it was written to provide. Detaching
    /// also lets page N+1 be fetched while page N is being analysed, and gives
    /// the enumeration something to check for cancellation.
    ///
    /// Only still images are enumerated (no videos): Vision analysis is for
    /// stills, and videos reach the UI through their own category fetches.
    func assetPages(scope: ScanScope) -> AsyncStream<AssetPage> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [pageSize] in
                let fetch = PHAsset.fetchAssets(with: .image, options: Self.options(scope: scope))

                let total = fetch.count
                guard total > 0 else {
                    continuation.finish()
                    return
                }

                var pageIndex = 0
                var start = 0
                while start < total {
                    if Task.isCancelled { break }

                    let end = min(start + pageSize, total)
                    var page: [PhotoAsset] = []
                    page.reserveCapacity(end - start)

                    // `enumerateObjects(at:)` faults assets in lazily for just
                    // this window; each `phAsset` is released as it advances.
                    fetch.enumerateObjects(at: IndexSet(integersIn: start..<end), options: []) { phAsset, _, _ in
                        page.append(Self.snapshot(phAsset))
                    }

                    continuation.yield(
                        AssetPage(
                            assets: page,
                            pageIndex: pageIndex,
                            isLastPage: end >= total,
                            totalCount: total
                        )
                    )
                    pageIndex += 1
                    start = end
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Snapshots specific assets by identifier.
    ///
    /// - Parameter imagesOnly: when `true`, videos are dropped. Correct for the
    ///   analysis delta (Vision only runs on stills) and **wrong** for anything
    ///   that has to show the user their own assets back.
    ///
    ///   That distinction was a real bug: the ignore list was rendered through
    ///   this method with the filter always on, so ignoring a video removed it
    ///   from every suggestion but never showed it on the Ignored screen. The
    ///   decision was invisible *and* impossible to undo — the worst combination
    ///   for a feature whose entire job is letting people take a choice back.
    func snapshots(for identifiers: [String], imagesOnly: Bool = true) -> [PhotoAsset] {
        guard !identifiers.isEmpty else { return [] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var result: [PhotoAsset] = []
        fetched.enumerateObjects { asset, _, _ in
            if !imagesOnly || asset.mediaType == .image {
                result.append(Self.snapshot(asset))
            }
        }
        return result
    }

    /// Fetches all screenshots (newest first) from the system "Screenshots"
    /// smart album, as `Sendable` snapshots.
    func fetchScreenshots(scope: ScanScope) async -> [PhotoAsset] {
        assets(inSmartAlbum: .smartAlbumScreenshots, scope: scope)
    }

    /// Photos iOS itself identifies as selfies, from the system "Selfies" smart
    /// album.
    ///
    /// This replaces an earlier heuristic ("a face fills much of the frame"),
    /// which was simply wrong: that describes a close-up PORTRAIT, so photos a
    /// parent takes of their child matched it perfectly. What actually makes a
    /// selfie is the front-facing camera, which iOS tracks and exposes here — so
    /// this is both more correct and free (no Vision pass needed).
    func fetchSelfies(scope: ScanScope) async -> [PhotoAsset] {
        assets(inSmartAlbum: .smartAlbumSelfPortraits, scope: scope)
    }

    private func assets(
        inSmartAlbum subtype: PHAssetCollectionSubtype,
        scope: ScanScope
    ) -> [PhotoAsset] {
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: subtype,
            options: nil
        )
        guard let album = albums.firstObject else { return [] }

        let assets = PHAsset.fetchAssets(in: album, options: Self.options(scope: scope))
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
    /// the (not cheap) `PHAssetResource` lookup for each one again.
    ///
    /// Screen recordings are detected heuristically: iOS exposes no public
    /// smart-album subtype for them, so we match ReplayKit's filename signature
    /// (`RPReplay_Final…`). A recording the user renamed won't be detected —
    /// acceptable, since that only means it doesn't appear, never a false
    /// deletion.
    func fetchVideosAndScreenRecordings(scope: ScanScope) async -> (videos: [PhotoAsset], recordings: [PhotoAsset]) {
        let assets = PHAsset.fetchAssets(with: .video, options: Self.options(scope: scope))

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

    /// Candidate set for the "Big files" category: every Live Photo plus the
    /// highest-resolution stills (up to `stillLimit`). Reading real on-disk size
    /// for a whole library is expensive, so we bound the pool cheaply here —
    /// resolution is a good proxy for which stills are large — and let the caller
    /// measure exact sizes for just this set via `fileSizes(for:)`.
    ///
    /// Note: `PHFetchOptions` only supports sorting by creation/modification
    /// date, so we do NOT sort the fetch by resolution (that would raise at
    /// runtime). We snapshot into value types — releasing each `PHAsset` as the
    /// lazy enumeration advances, so peak memory stays bounded — then rank the
    /// (small) `PhotoAsset` snapshots by pixel area in memory.
    func fetchLargeFileCandidates(scope: ScanScope, stillLimit: Int) async -> [PhotoAsset] {
        let assets = PHAsset.fetchAssets(with: .image, options: Self.options(scope: scope, sorted: false))

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
    /// value type, so no `PHAsset` ever escapes this file.
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

    /// Loads a downscaled `CGImage` for analysis by identifier.
    ///
    /// iCloud handling matters for correctness, not just completeness. With
    /// "Optimize iPhone Storage" many assets exist locally only as a small
    /// degraded thumbnail. Analysing *that* would be actively wrong: Laplacian
    /// sharpness measured on a downscaled thumbnail is artificially low (a sharp
    /// photo would be reported blurry) and its feature print wouldn't match the
    /// full-resolution one, breaking duplicate detection. So a degraded image is
    /// never accepted — we report `.inCloud` and let the caller decide.
    ///
    /// - Parameter targetSize: the square bound to downscale into. Supplied by
    ///   the caller from `AnalysisConfiguration` rather than fixed here, because
    ///   it is a measured trade-off between analysis cost and detection quality
    ///   — see `AnalysisConfiguration.analysisImageSize`.
    func analysisImage(
        for localIdentifier: String,
        targetSize: Int,
        allowNetwork: Bool = false
    ) async -> AnalysisImage {
        guard let asset = Self.fetchAsset(localIdentifier) else { return .unavailable }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false

        let size = CGSize(width: targetSize, height: targetSize)

        return await withCheckedContinuation { continuation in
            let box = ResumeOnce()
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false

                if isDegraded {
                    // Only a placeholder so far. If the real one is in iCloud and
                    // we may not fetch it, no better callback is coming — resolve
                    // now rather than waiting forever.
                    if isInCloud, !allowNetwork, box.claim() {
                        continuation.resume(returning: .inCloud)
                    }
                    return
                }

                guard box.claim() else { return }
                if let cgImage = image?.cgImage {
                    continuation.resume(returning: .image(cgImage))
                } else if isInCloud {
                    continuation.resume(returning: .inCloud)
                } else {
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    private static func fetchAsset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    // MARK: - UI thumbnails

    // These three stay `@MainActor`, unlike everything else in this file.
    //
    // `UIImage` is not `Sendable`, so handing one back from a nonisolated async
    // method means a non-Sendable value crossing an isolation boundary — the
    // kind of thing that either fails to compile under strict concurrency or
    // compiles today and breaks on a compiler update. There is also nothing to
    // gain: the expensive decode happens inside `PHImageManager` on its own
    // queue either way, and these are per-tile and lazy, so the main actor is
    // only ever briefly occupied. The bottleneck this file was refactored to
    // remove was the bulk enumeration, not thumbnails.

    /// Square-cropped thumbnail for a filmstrip tile.
    ///
    /// Unlike analysis, UI image requests permit network access so iCloud-only
    /// photos still render.
    @MainActor
    func thumbnail(for localIdentifier: String, targetSize: CGSize) async -> UIImage? {
        await requestUIImage(localIdentifier, targetSize: targetSize, contentMode: .aspectFill)
    }

    /// Large, aspect-fit image for the full-screen preview (whole photo visible).
    @MainActor
    func previewImage(for localIdentifier: String, targetSize: CGSize) async -> UIImage? {
        await requestUIImage(localIdentifier, targetSize: targetSize, contentMode: .aspectFit)
    }

    @MainActor
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
            let box = ResumeOnce()
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }        // wait for the full-quality pass
                guard box.claim() else { return }
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - On-disk sizes

    /// Total on-disk byte size for each asset id, in one query.
    ///
    /// Sums every `PHAssetResource` for the asset (original + any edited render),
    /// which is what deleting it actually frees. `fileSize` isn't a public
    /// property, so we read it via KVC — the long-standing, widely-used approach;
    /// assets whose size can't be read are simply omitted.
    ///
    /// This replaces a former pair of near-identical methods (`fileSizes` and
    /// `assetFileSizes`) that differed only in isolation. With the service off
    /// the main actor there is only one correct version.
    func fileSizes(for identifiers: [String]) async -> [String: Int64] {
        guard !identifiers.isEmpty else { return [:] }
        return Self.sizes(of: PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil))
    }

    /// On-disk size of every asset **within the given scope**, keyed by id.
    ///
    /// One pass serves two jobs: summing it gives the dashboard's total, and the
    /// per-asset sizes are the cheap pre-filter `ExactDuplicateFinder` uses to
    /// find identical copies.
    ///
    /// The scope predicate is not an optimisation detail — it was missing, and
    /// its absence meant this walked the *entire* library even when the user had
    /// asked for "past month". Measured at 2.2 s for 228 assets (~9.6 ms each,
    /// dominated by the `PHAssetResource` lookup), which extrapolates to minutes
    /// on a large library — the single most expensive thing the app does, and
    /// the one place the app's only cost lever did nothing at all.
    func libraryFileSizes(scope: ScanScope) async -> [String: Int64] {
        let options = Self.options(scope: scope, sorted: false)
        return Self.sizes(of: PHAsset.fetchAssets(with: options))
    }

    private static func sizes(of fetched: PHFetchResult<PHAsset>) -> [String: Int64] {
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

    // MARK: - Albums

    /// Creates a new Photos album containing the given assets.
    ///
    /// This only *references* existing assets in a new collection — nothing is
    /// copied, nothing is removed, and the originals stay exactly where they are.
    func createAlbum(named title: String, withAssetIDs ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            // Note: this returns a NON-optional in Swift, so no `guard let`.
            let request = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: title)
            request.addAssets(assets)
        }
    }

    // MARK: - Deletion

    /// Deletes assets by identifier. **This is the only method that removes
    /// photos, and it is only ever invoked after explicit user confirmation in
    /// the UI.** The system also shows its own confirmation sheet.
    ///
    /// `PHPhotoLibrary` runs the change block *and* fires its completion on its
    /// own private queue. When this service was `@MainActor`, awaiting that from
    /// the main actor made the Swift 6 runtime's isolation check trap
    /// (`EXC_BREAKPOINT`) — a real crash that had to be fixed with an explicit
    /// `nonisolated`. Now that the whole service is off the main actor, that
    /// hazard is structural rather than remembered. The assets are still fetched
    /// *inside* the change block so no non-`Sendable` `PHFetchResult` crosses the
    /// `@Sendable` boundary.
    ///
    /// - Returns: `true` if the user confirmed and deletion succeeded.
    @discardableResult
    func deleteAssets(withIdentifiers ids: [String]) async throws -> Bool {
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

/// Guards a `CheckedContinuation` against the multiple callbacks
/// `PHImageManager` can deliver for one request.
///
/// A plain `var didResume` captured by the callback was fine while this service
/// was main-actor isolated and the callbacks arrived serially. Off the main
/// actor that is a mutable capture in a `@Sendable` closure — resuming a
/// continuation twice is a hard crash, so the guard needs to be genuinely
/// atomic rather than merely single-threaded by accident.
///
/// It hands out *permission* rather than performing the resume itself, which
/// looks clumsier than a `resume(_:with:)` helper and is deliberate.
/// `CheckedContinuation.resume(returning:)` takes a `sending` parameter, and
/// forwarding an unconstrained generic `T` into it fails to compile — "sending
/// 'value' risks causing data races" — because a helper that merely received
/// the value can't prove it is disconnected from its original region. Resuming
/// at the original call site keeps the value's region exactly where the
/// compiler can still reason about it.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    /// Returns `true` for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasResumed { return false }
        hasResumed = true
        return true
    }
}
