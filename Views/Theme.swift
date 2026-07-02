//
//  Theme.swift
//  TidyGallery
//
//  Semantic design tokens for a polished, dark-mode-first look. Everything the
//  UI draws pulls colour, spacing, radius, and typography from here — no raw
//  hex or magic numbers scattered through the views. Colours are defined as
//  dynamic (light/dark) values so both themes are designed together and meet
//  contrast targets.
//

import SwiftUI
import UIKit

enum Theme {

    // MARK: Colour tokens (semantic, dynamic light/dark)

    enum Colors {
        /// App background — near-black in dark, off-white in light.
        static let background = dynamic(light: 0xF2F2F7, dark: 0x0B0B0F)
        /// Card / elevated surface.
        static let surface = dynamic(light: 0xFFFFFF, dark: 0x1C1C22)
        /// Subtle raised surface (filmstrip wells, chips).
        static let surfaceMuted = dynamic(light: 0xE9E9EF, dark: 0x2A2A32)

        static let textPrimary = dynamic(light: 0x11131A, dark: 0xF5F6FA)
        static let textSecondary = dynamic(light: 0x5A5E6B, dark: 0x9AA0AE)

        /// Brand accent — calm indigo, used for primary actions & selection.
        static let accent = dynamic(light: 0x4C5BD4, dark: 0x8B95F2)
        /// "Best shot" highlight — warm amber for the star badge/ring.
        static let best = dynamic(light: 0xE8A317, dark: 0xFFC64B)
        /// Destructive — for delete affordances and the confirm button.
        static let destructive = dynamic(light: 0xD9382C, dark: 0xFF6B5E)

        static let hairline = dynamic(light: 0xD8D8E0, dark: 0x33333D)

        private static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(UIColor { traits in
                UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
            })
        }
    }

    // MARK: Spacing (8pt rhythm)

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Radius

    enum Radius {
        static let tile: CGFloat = 12
        static let card: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: Elevation

    static func cardShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black.opacity(0.5) : .black.opacity(0.10)
    }
}

// MARK: - UIColor hex helper

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Environment injection for the photo library service

extension EnvironmentValues {
    /// The photo library service, injected at the app root so any tile can load
    /// its own thumbnail. Optional so the default (no service) is concurrency-safe.
    @Entry var photoLibrary: PhotoLibraryService? = nil
}
