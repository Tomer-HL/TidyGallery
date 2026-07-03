//
//  PhotoTileView.swift
//  TidyGallery
//
//  One photo in a stack's filmstrip. Loads its own thumbnail asynchronously and
//  overlays the state controls:
//   • Tap the photo        → open the full-screen preview (see it big, then decide).
//   • ★ button (top-left)  → promote to best shot.
//   • ◯/✓ (bottom-right)   → quick toggle keep/delete (hidden for the best shot).
//  Photos queued for deletion dim and shrink slightly so the outcome is obvious.
//

import SwiftUI
import UIKit

struct PhotoTileView: View {
    let assetID: PhotoAsset.ID
    let isBestShot: Bool
    let isChecked: Bool
    let onOpenPreview: () -> Void
    let onToggleDeletion: () -> Void
    let onMakeBest: () -> Void

    @Environment(\.photoLibrary) private var library
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private let side: CGFloat = 112

    var body: some View {
        ZStack {
            thumbnail
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isBestShot ? 2.5 : 1)
                }
                .opacity(isChecked ? 0.55 : 1)
                .scaleEffect(isChecked ? 0.97 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isChecked)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .onTapGesture { onOpenPreview() }

            starBadge
                .frame(width: side, height: side, alignment: .topLeading)
            selectionControl
                .frame(width: side, height: side, alignment: .bottomTrailing)
        }
        .frame(width: side, height: side)
        .task(id: assetID) { await loadThumbnail() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Pieces

    private var thumbnail: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Theme.Colors.surfaceMuted
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
    }

    /// Amber star for the best shot; a tappable star otherwise. The translucent
    /// disc keeps the glyph legible over any photo.
    private var starBadge: some View {
        Button(action: onMakeBest) {
            Image(systemName: isBestShot ? "star.fill" : "star")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isBestShot ? Theme.Colors.best : .white)
                .padding(6)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel(isBestShot ? "Best shot" : "Make best shot")
    }

    /// Persistent selection circle for quick keep/delete toggling. Hidden for the
    /// best shot, which can never be deleted.
    @ViewBuilder private var selectionControl: some View {
        if !isBestShot {
            Button(action: onToggleDeletion) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isChecked ? Theme.Colors.destructive : .black.opacity(0.35))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel(isChecked ? "Marked for deletion, tap to keep" : "Kept, tap to mark for deletion")
        }
    }

    private var borderColor: Color {
        if isBestShot { return Theme.Colors.best }
        if isChecked { return Theme.Colors.destructive }
        return Theme.Colors.hairline
    }

    private var accessibilityText: String {
        if isBestShot { return "Photo, best shot" }
        return isChecked ? "Photo, marked for deletion" : "Photo, kept"
    }

    private func loadThumbnail() async {
        guard image == nil, let library else { return }
        let px = side * displayScale
        image = await library.thumbnail(for: assetID, targetSize: CGSize(width: px, height: px))
    }
}
