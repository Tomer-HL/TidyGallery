//
//  ItemNoun.swift
//  TidyGallery
//
//  The nouns this app counts things in, and the single place plural forms are
//  produced.
//
//  Why this type exists
//  --------------------
//  The app used to build counts by appending a letter: `noun + "s"`, and
//  `"\(count) photo\(count == 1 ? "" : "s")"`. That is not a shortcut, it is a
//  hard-coded assumption that the interface is English — and it is wrong even in
//  English the moment a noun is irregular ("cop" + "ies" was already being
//  special-cased at two call sites).
//
//  Hebrew makes the assumption untenable. Its plural categories are one, TWO,
//  many and other — "שתי תמונות" for exactly two is a distinct form, not a
//  variant of the general plural — and the noun itself changes shape rather than
//  taking a suffix (תמונה → תמונות, סרטון → סרטונים). No amount of string
//  concatenation produces that.
//
//  So counts go through `.stringsdict`, which is the platform's plural-rule
//  engine: the localisation supplies one entry per plural category and the
//  system picks using the target language's CLDR rules. Nothing here needs to
//  know which categories a language has.
//
//  Why `.stringsdict` and not a String Catalog: the catalog is the newer format
//  and Xcode maintains it for you, but this project is built entirely in CI with
//  no Mac to open Xcode on, so every localisation file is authored by hand.
//  `.strings`/`.stringsdict` are simple, stable, and unambiguous to write
//  correctly without a GUI. That's the deciding factor here.
//

import Foundation

/// A countable thing the interface refers to. Each case owns a `.stringsdict`
/// key whose plural forms are defined per language.
enum ItemNoun: String, Sendable, Hashable, CaseIterable {
    case photo
    case video
    case screenshot
    case recording
    case document
    case selfie
    case foodPhoto
    case petPhoto
    case copy
    /// A cluster of visually similar photos.
    case group
    /// Photos inside one duplicate stack.
    case similarPhoto
    /// A conservative duplicate suggestion on the home dashboard.
    case safeDuplicate

    /// The `.stringsdict` key holding this noun's plural forms.
    var pluralKey: String { "count.\(rawValue)" }

    /// A localized, correctly pluralized count phrase — "3 screenshots",
    /// "צילום מסך אחד", "שתי תמונות".
    ///
    /// `localizedStringWithFormat` (not `String(format:)`) is required: it is the
    /// call that expands a `.stringsdict` plural variable against the current
    /// locale's rules. Plain `String(format:)` would substitute the argument
    /// without ever consulting them.
    func counted(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString(pluralKey, comment: "Count of items, pluralized"),
            count
        )
    }

    /// Capitalized singular, for accessibility labels ("Photo", "Video").
    var singularName: String {
        NSLocalizedString("noun.\(rawValue).singular", comment: "Singular noun, capitalized")
    }
}
