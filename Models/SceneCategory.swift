//
//  SceneCategory.swift
//  TidyGallery
//
//  High-level content categories for a photo. Most are derived from Apple's
//  on-device Vision image classifier (`VNClassifyImageRequest`), which returns a
//  large flat taxonomy of labels ("food", "pizza", "mountain", ...).
//
//  Selfies deliberately are NOT here: they're identified from the system
//  "Selfies" smart album (front-camera capture), because a face filling the
//  frame describes a close-up portrait, not a selfie.
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

    /// Whole-word tokens (lowercased) in a Vision classification identifier that
    /// map an observation to this category. Matching is token-based (identifiers
    /// are split on non-letters) so "category" does not match "cat".
    ///
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
                // "roll" and "bun" are omitted: too generic to be safe.
                "bakery", "baked", "loaf", "dough", "toast",
                "croissant", "pie", "cookie", "cheese", "egg", "meat"
            ]
        case .pets:
            return ["dog", "cat", "puppy", "kitten", "kitty", "pet", "pets"]
        case .documents:
            // Deliberately narrow, and narrowed again after real-device testing
            // filed product boxes and fabric swatches as documents. Two tokens
            // were pulled for leaking onto packaging: "book" matched "book
            // jacket" (Vision's label for a printed box/sleeve), and "page" is
            // generic enough to catch any flat printed surface. "menu" is kept
            // but it is the next-weakest — it also fires on product labels.
            //
            // Keyword matching on a general classifier can only get documents so
            // far: a cereal box genuinely does contain text. The face and nature
            // vetoes in `refined(fromLabels:hasFaces:)` remove the rest of the
            // visible errors (people, scenery), which is most of them.
            return [
                "document", "documents", "text", "paper", "receipt", "menu",
                "invoice", "whiteboard", "newspaper",
                "books", "handwriting", "handwritten", "notebook"
            ]
        case .nature:
            return [
                "landscape", "mountain", "mountains", "beach", "sunset", "sunrise",
                "sky", "cloud", "clouds", "forest", "tree", "trees", "ocean", "sea",
                "lake", "river", "waterfall", "nature", "scenery", "valley",
                "desert", "canyon", "coast", "cliff", "glacier", "meadow", "field",
                "hill", "hills"
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
    /// categories they imply. The RAW mapping — token match only.
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

    /// Classifier tokens that mean "there are people in this photo", used as a
    /// second people signal alongside face detection.
    ///
    /// Face detection runs on the ~512px analysis image, where a person who is
    /// small in a wide scene — someone standing in a landscape, a face in a
    /// crowd — is below the size the detector resolves. So scenic shots with
    /// distant people slipped past the face veto. The scene CLASSIFIER sees the
    /// whole frame and labels it "people" / "crowd" / "baby" regardless of how
    /// large any one face is, which is exactly the gap face detection leaves.
    private static let peopleTokens: Set<String> = [
        "people", "person", "persons", "crowd", "audience", "portrait", "selfie",
        "baby", "toddler", "infant", "child", "children",
        "bride", "groom", "wedding"
    ]

    private static func labelsIndicatePeople(_ identifiers: [String]) -> Bool {
        for identifier in identifiers where !peopleTokens.isDisjoint(with: tokens(of: identifier)) {
            return true
        }
        return false
    }

    /// Classifier tokens that mean "a vehicle is the subject". A car
    /// photographed outdoors picks up "outdoor"/"tree" from whatever is behind
    /// it and lands in scenery — but a photo OF a car is no more a landscape
    /// than a photo of a person is. So a prominent vehicle vetoes nature too.
    ///
    /// Judged on the STRONG labels (unlike people, which is judged eagerly),
    /// because a car should be the subject to count: a distant car in a genuine
    /// vista shouldn't strip the vista out of Nature.
    private static let vehicleTokens: Set<String> = [
        "car", "cars", "vehicle", "automobile", "truck", "motorcycle",
        "motorbike", "scooter", "bus", "van", "jeep", "suv"
    ]

    private static func labelsIndicateVehicle(_ identifiers: [String]) -> Bool {
        for identifier in identifiers where !vehicleTokens.isDisjoint(with: tokens(of: identifier)) {
            return true
        }
        return false
    }

    /// The categories a photo actually belongs to, after the product rules that
    /// the raw token match can't express on its own.
    ///
    /// The classifier answers "what is in this frame". The categories answer
    /// "what is this a photo OF", which is a different question:
    ///
    ///   - A person in the frame makes it a photo of the person. "A child eating
    ///     pizza" is not a food photo; "a family at the beach" is not a scenery
    ///     photo. People therefore veto food, nature and documents. (Pets are
    ///     left alone — a person holding a cat is still a cat photo.)
    ///
    ///     "A person" is BOTH a detected face and a people label from the
    ///     classifier, because neither catches every case: face detection misses
    ///     small/distant people, and the classifier misses a lone face it reads
    ///     as a portrait subject rather than a scene. Together they close most
    ///     of the gap.
    ///
    ///   - A document is an indoor, flat, printed thing. A landscape is not one,
    ///     however much text a sign in it carries — so nature vetoes documents.
    ///     This alone fixes the mountains-filed-as-a-document case.
    ///
    /// Computed from stored data (labels + face count), NOT baked into the
    /// cache, so these rules can be tuned without re-analysing the library.
    ///
    /// Confidence-aware. Real-device output showed a document photo — the
    /// classifier 90% sure it was a Document — filed under Nature because it also
    /// drew a 38% "sky". Identifier-only matching gave that 38% label the same
    /// weight as the 90% one. This classifier "spreads confidence across a very
    /// large taxonomy", so weak incidental labels are the norm, not the
    /// exception. A label therefore only assigns a category when it is strong
    /// RELATIVE to the photo's own top label — which adapts to that spread
    /// rather than fighting it with a fixed cutoff.
    static func refined(
        from labels: [ClassificationLabel],
        hasFaces: Bool,
        relativeFloor: Float = 0.5,
        absoluteFloor: Float = 0.3,
        peopleFloor: Float = 0.25
    ) -> Set<SceneCategory> {
        let topConfidence = labels.map(\.confidence).max() ?? 0
        let categoryFloor = max(absoluteFloor, topConfidence * relativeFloor)

        // Category assignment is STRICT: a token counts only if it's strong
        // relative to the photo's top label, so a weak incidental "sky" can't
        // tag a document as nature.
        let strong = labels.filter { $0.confidence >= categoryFloor }.map(\.identifier)
        var tags = categories(forIdentifiers: strong)

        // People detection is EAGER, and deliberately NOT gated by the strict
        // floor above. Faces are missed on the 512px analysis image, and a
        // "crowd"/"person" label is often weak next to a dominant "concert" or
        // "mountain" — filtering those out (which the strict floor did) is what
        // left people in Nature. Any people hint above a low floor now vetoes.
        let peopleLabels = labels.filter { $0.confidence >= peopleFloor }.map(\.identifier)
        let hasPeople = hasFaces || labelsIndicatePeople(peopleLabels)
        if hasPeople {
            tags.remove(.food)
            tags.remove(.nature)
            tags.remove(.documents)
        }

        // A prominent vehicle is a subject, not scenery.
        if labelsIndicateVehicle(strong) {
            tags.remove(.nature)
        }

        if tags.contains(.nature) {
            tags.remove(.documents)
        }
        return tags
    }

    /// Identifier-only convenience for callers and tests that don't carry
    /// confidence — every label is treated as equally, fully confident, so the
    /// relative floor passes them all and the behaviour is the plain token map
    /// plus the vetoes.
    static func refined(fromLabels labels: [String], hasFaces: Bool) -> Set<SceneCategory> {
        refined(
            from: labels.map { ClassificationLabel(identifier: $0, confidence: 1) },
            hasFaces: hasFaces
        )
    }
}
