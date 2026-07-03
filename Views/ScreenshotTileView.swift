//
//  ScreenshotTileView.swift
//  TidyGallery
//
//  A single screenshot in the grid. Loads its thumbnail, shows a selection
//  circle, and dims when selected. Tap toggles selection.
//

import SwiftUI
import UIKit

struct ScreenshotTileView: View {
    let assetID: PhotoAsset.ID
    let isSelected: Bool
    let onToggle: () -> Void

    @Environment(\.photoLibrary) private var library
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                thumbnail.scaledToFill()
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .strokeBorder(isSelected ? Theme.Colors.accent : Theme.Colors.hairline,
                                  lineWidth: isSelected ? 2.5 : 1)
            }
            .overlay(alignment: .bottomTrailing) { selectionCircle }
            .opacity(isSelected ? 0.7 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .onTapGesture { onToggle() }
            .task(id: assetID) { await load() }
            .accessibilityLabel(isSelected ? "Screenshot, selected" : "Screenshot")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var thumbnail: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Theme.Colors.surfaceMuted.overlay { ProgressView().controlSize(.small) }
            }
        }
    }

    private var selectionCircle: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, isSelected ? Theme.Colors.accent : .black.opacity(0.35))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .padding(6)
    }

    private func load() async {
        guard image == nil, let library else { return }
        let px = 200 * displayScale
        image = await library.thumbnail(for: assetID, targetSize: CGSize(width: px, height: px))
    }
}
