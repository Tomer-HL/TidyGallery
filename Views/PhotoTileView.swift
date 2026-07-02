//
//  PhotoTileView.swift
//  TidyGallery
//
//  One photo in a stack's filmstrip. Loads its own thumbnail asynchronously,
//  overlays the state badges (★ best shot / ✓ marked for deletion), and dims
//  photos queued for removal so the "what will disappear" is obvious at a glance.
//
//  Interactions:
//   • Tap            → toggle deletion (unless it's the best shot).
//   • Star button    → promote this photo to best shot.
//  Both have ≥44pt hit areas and animate with a subtle spring.
//

import SwiftUI
import UIKit

struct PhotoTileView: View {
    let assetID: PhotoAsset.ID
    let isBestShot: Bool
    let isChecked: Bool
    let onToggleDeletion: () -> Void
    let onMakeBest: () -> Void

    @Environment(\.photoLibrary) private var library
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private let side: CGFloat = 112

    var body: some View {
        ZStack(alignment: .topLeading) {
            thumbnail
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isBestShot ? 2.5 : 1)
                }
                .overlay(alignment: .bottomTrailing) { deletionBadge }
                .opacity(isChecked ? 0.55 : 1)
                .scaleEffect(isChecked ? 0.97 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isChecked)

            starBadge
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .onTapGesture { if !isBestShot { onToggleDeletion() } }
        .task(id: assetID) { await loadThumbnail() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isChecked ? [.isSelected] : [])
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

    /// Amber star for the best shot; a tappable star outline otherwise. The
    /// translucent disc keeps the glyph legible over any photo.
    private var starBadge: some View {
        Button(action: onMakeBest) {
            Image(systemName: isBestShot ? "star.fill" : "star")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isBestShot ? Theme.Colors.best : .white)
                .padding(6)
                .background(.black.opacity(0.4), in: Circle())
                .padding(6)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44, alignment: .topLeading)
        .accessibilityLabel(isBestShot ? "Best shot" : "Make best shot")
    }

    @ViewBuilder private var deletionBadge: some View {
        if isChecked {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white, Theme.Colors.destructive)
                .padding(6)
                .transition(.scale.combined(with: .opacity))
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
