//
//  AssetTileView.swift
//  TidyGallery
//
//  A single asset in a cleanup grid. Loads its thumbnail, shows a selection
//  circle, an optional metadata subtitle (size / duration), and a play glyph for
//  videos. Tap toggles selection. Used by every `AssetCleanupScreen` category.
//

import SwiftUI
import UIKit

struct AssetTileView: View {
    let assetID: PhotoAsset.ID
    let isSelected: Bool
    let isVideo: Bool
    /// Optional caption drawn along the bottom, e.g. "24.1 MB" or "1:32 · 88 MB".
    let subtitle: String?
    /// What this tile holds, for the accessibility label.
    let noun: ItemNoun
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
            .overlay(alignment: .topLeading) { if isVideo { playGlyph } }
            .overlay(alignment: .bottom) { if let subtitle { caption(subtitle) } }
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
            // `.capitalized` is gone on purpose: it's a Latin-script habit that
            // does nothing in Hebrew (which has no letter case) and mangles
            // some languages outright. The localization supplies the noun in the
            // form it should be read aloud in.
            .accessibilityLabel(
                isSelected
                    ? String(localized: "\(noun.singularName), selected")
                    : noun.singularName
            )
            .accessibilityValue(subtitle ?? "")
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

    private var playGlyph: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 20, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.35))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .padding(6)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
            )
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
