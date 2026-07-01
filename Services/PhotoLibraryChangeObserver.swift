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
final class PhotoLibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {

    private var fetchResult: PHFetchResult<PHAsset>
    private let continuation: AsyncStream<LibraryChange>.Continuation
    let changes: AsyncStream<LibraryChange>

    override init() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        self.fetchResult = PHAsset.fetchAssets(with: .image, options: options)

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
