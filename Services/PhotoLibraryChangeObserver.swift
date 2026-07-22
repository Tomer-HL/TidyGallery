//
//  PhotoLibraryChangeObserver.swift
//  TidyGallery
//
//  Bridges `PHPhotoLibraryChangeObserver` (a delegate-style callback) into a
//  modern `AsyncStream` of change events, so the scan coordinator can react to
//  inserted/updated/deleted assets and re-analyse only the delta.
//

import Foundation
import Photos

/// A `Sendable` description of what changed since the last snapshot.
struct LibraryChange: Sendable {
    /// Identifiers of assets newly inserted or modified — need (re)analysis.
    let changedIdentifiers: [String]
    /// Identifiers of assets removed — purge from cache.
    let removedIdentifiers: [String]
}

/// Observes the photo library and republishes changes as an `AsyncStream`.
///
/// `PHPhotoLibraryChangeObserver` requires an `NSObject` conformer, so this
/// wrapper adapts it. It compares against a baseline `PHFetchResult` it holds,
/// applying `PHFetchResultChangeDetails` to compute inserted/removed sets.
///
/// Concurrency: why `@unchecked Sendable` is honest here
/// ----------------------------------------------------
/// `fetchResult` is mutable state with no lock around it, which is exactly the
/// shape `@unchecked` is usually used to paper over. What makes it safe is a
/// documented guarantee the compiler can't see: `photoLibraryDidChange(_:)` is
/// the only thing that touches it, and PhotoKit delivers that callback
/// serially — one at a time, never re-entrantly, on a queue it owns. So the
/// read at the top and the write below can't interleave with another call.
///
/// `AsyncStream.Continuation` is documented as `Sendable` and safe to yield to
/// from anywhere, so the other stored property needs no argument at all.
///
/// The rest of the codebase states its reasoning where it waives a check (see
/// `PhotoLibraryService`); this file was claiming the waiver without it.
final class PhotoLibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {

    private var fetchResult: PHFetchResult<PHAsset>
    private let continuation: AsyncStream<LibraryChange>.Continuation
    let changes: AsyncStream<LibraryChange>

    override init() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // Every media type, not just `.image`.
        //
        // The baseline used to be images only, which meant deleting a video —
        // in Photos.app or in this app — produced no `LibraryChange` at all.
        // `LibraryScanCoordinator.apply(_:)` never ran for it, so the analysis
        // and size caches kept their rows for a video that no longer existed,
        // accumulating for the app's lifetime, and the Large videos / Screen
        // recordings counts stayed stale until the next full scan.
        //
        // `fetchAssets(with:options:)` has no "all media types" overload — the
        // enum has no such case — so the unfiltered `fetchAssets(with options:)`
        // is the way to ask for everything.
        self.fetchResult = PHAsset.fetchAssets(with: options)

        var cont: AsyncStream<LibraryChange>.Continuation!
        self.changes = AsyncStream { cont = $0 }
        self.continuation = cont

        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        continuation.finish()
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let details = changeInstance.changeDetails(for: fetchResult) else { return }

        // Advance our baseline to the post-change state.
        let updatedResult = details.fetchResultAfterChanges
        self.fetchResult = updatedResult

        let inserted = details.insertedObjects.map(\.localIdentifier)
        let changed = details.changedObjects.map(\.localIdentifier)
        let removed = details.removedObjects.map(\.localIdentifier)

        guard !inserted.isEmpty || !changed.isEmpty || !removed.isEmpty else { return }

        continuation.yield(
            LibraryChange(
                changedIdentifiers: inserted + changed,
                removedIdentifiers: removed
            )
        )
    }
}
