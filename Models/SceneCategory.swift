//
//  SceneCategory.swift
//  TidyGallery
//
//  High-level content categories for a photo. Most are derived from Apple's
//  on-device Vision image classifier (`VNClassifyImageRequest`), which returns a
//  large flat taxonomy of labels ("food", "pizza", "mountain", ...). A few (like
//  `.selfies`) come from a different on-device signal (face geometry) and are
//  added by the analyzer directly rather than mapped from a classifier label.
//
//  Everything here is pure and `Sendable` so it can cross the analyzer actor
//  boundary and be cached as value types.
//

import Foundation

/// A product-facing content category a photo can belong to. A photo may match
/// several, so callers work with a `Set<SceneCategory>`.
enum SceneCategory: String, Sendable, Codable, Hashable, CaseIterable {
    case food
    case pets
    case documents
    case nature
    case selfies

    /// Whole-word tokens (lowercased) in a Vision classification identifier that
    /// map an observation to this category. Matching is token-based (identifiers
    /// are split on non-letters) so "category" does not match "cat".
    ///
    /// Categories that are NOT derived from the classifier (e.g. `.selfies`,
    /// which the analyzer decides from face size) return an empty set here and
    /// are never produced by `categories(forIdentifiers:)`.
    var matchTokens: Set<String> {
        switch self {
        case .food:
            return [
                "food", "meal", "dish", "cuisine", "dessert", "fruit", "vegetable",
                "drink", "beverage", "breakfast", "lunch", "dinner", "snack",
                "bread", "cake", "pizza", "burger", "hamburger", "sushi", "salad",
                "soup", "pasta", "coffee", "sandwich", "seafood", "pastry",
                "noodle", "noodles", "rice", "cocktail", "wine", "hotdog",
                // Baked goods (a challah reads as bread/loaf/bakery to Vision).
                "bakery", "baked", "loaf", "bun", "roll", "dough", "toast",
                "croissant", "pie", "cookie", "cheese", "egg", "meat", "chicken"
            ]
        case .pets:
            return ["dog", "cat", "puppy", "kitten", "kitty", "pet", "pets"]
        case .documents:
            return [
                "document", "documents", "text", "paper", "receipt", "menu",
                "invoice", "whiteboard", "newspaper",
                // A photographed book/notebook page reads as book/page/print.
                "book", "books", "page", "handwriting", "handwritten", "note",
                "notes", "notebook", "letter", "print", "printout", "magazine",
                "poster", "sign", "label", "card", "screenshot"
            ]
        case .nature:
            return [
                "landscape", "mountain", "mountains", "beach", "sunset", "sunrise",
                "sky", "cloud", "clouds", "forest", "tree", "trees", "ocean", "sea",
                "lake", "river", "waterfall", "nature", "scenery", "valley",
                "desert", "canyon", "coast", "cliff", "glacier", "meadow", "field",
                "hill", "hills"
            ]
        case .selfies:
            return []   // decided from face geometry, not classifier labels
        }
    }

    /// Splits a Vision identifier into lowercase word tokens.
    private static func tokens(of identifier: String) -> Set<String> {
        let lowered = identifier.lowercased()
        let parts = lowered.split { !$0.isLetter }
        return Set(parts.map(String.init))
    }

    /// Maps a set of confident classification identifiers to the high-level
    /// categories they imply. Categories with no match tokens (e.g. `.selfies`)
    /// are never produced here.
    static func categories(forIdentifiers identifiers: [String]) -> Set<SceneCategory> {
        var result: Set<SceneCategory> = []
        for identifier in identifiers {
            let toks = tokens(of: identifier)
            for category in SceneCategory.allCases
            where !category.matchTokens.isEmpty && !category.matchTokens.isDisjoint(with: toks) {
                result.insert(category)
            }
        }
        return result
    }
}
