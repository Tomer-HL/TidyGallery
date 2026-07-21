//
//  SceneCategory.swift
//  TidyGallery
//
//  High-level content categories derived from Apple's on-device Vision image
//  classifier (`VNClassifyImageRequest`). The classifier returns a large, flat
//  taxonomy of labels ("food", "pizza", "dog", "document", ...); we fold the
//  ones we care about into a few product-facing categories the UI can surface as
//  cleanup groups.
//
//  Everything here is pure and `Sendable` so it can cross the analyzer actor
//  boundary and be cached as value types.
//

import Foundation

/// A product-facing content category a photo can belong to. A photo may match
/// several (e.g. a plate of food on a documented menu), so callers work with a
/// `Set<SceneCategory>`.
enum SceneCategory: String, Sendable, Codable, Hashable, CaseIterable {
    case food
    case pets
    case documents

    /// Whole-word tokens (lowercased) in a Vision classification identifier that
    /// map an observation to this category. Matching is token-based (identifiers
    /// are split on `_`, `-`, and spaces) so "ice_cream" matches food via
    /// "cream"/"dessert"-style tokens without substring false positives.
    var matchTokens: Set<String> {
        switch self {
        case .food:
            return [
                "food", "meal", "dish", "cuisine", "dessert", "fruit", "vegetable",
                "drink", "beverage", "breakfast", "lunch", "dinner", "snack",
                "bread", "cake", "pizza", "burger", "hamburger", "sushi", "salad",
                "soup", "pasta", "coffee", "sandwich", "seafood", "pastry",
                "noodle", "noodles", "rice", "cocktail", "wine", "hotdog"
            ]
        case .pets:
            return ["dog", "cat", "puppy", "kitten", "kitty", "pet", "pets"]
        case .documents:
            return [
                "document", "documents", "text", "paper", "receipt", "menu",
                "invoice", "whiteboard", "newspaper"
            ]
        }
    }

    /// Splits a Vision identifier into lowercase word tokens.
    private static func tokens(of identifier: String) -> Set<String> {
        let lowered = identifier.lowercased()
        let parts = lowered.split { !$0.isLetter }
        return Set(parts.map(String.init))
    }

    /// Maps a set of confident classification identifiers to the high-level
    /// categories they imply.
    static func categories(forIdentifiers identifiers: [String]) -> Set<SceneCategory> {
        var result: Set<SceneCategory> = []
        for identifier in identifiers {
            let toks = tokens(of: identifier)
            for category in SceneCategory.allCases where !category.matchTokens.isDisjoint(with: toks) {
                result.insert(category)
            }
        }
        return result
    }
}
