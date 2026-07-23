//
//  SceneCategoryTests.swift
//  TidyGalleryTests
//
//  Locks the mapping from Vision classification identifiers to the app's
//  high-level content categories. Pure logic (no Vision), so it runs on the
//  simulator like the rest of the suite.
//

import Testing
@testable import TidyGallery

@Suite("Scene category mapping")
struct SceneCategoryTests {

    @Test("Food labels map to .food")
    func foodMapping() {
        #expect(SceneCategory.categories(forIdentifiers: ["pizza"]).contains(.food))
        #expect(SceneCategory.categories(forIdentifiers: ["food"]).contains(.food))
        #expect(SceneCategory.categories(forIdentifiers: ["salad"]).contains(.food))
    }

    @Test("Animal labels map to .pets")
    func petMapping() {
        #expect(SceneCategory.categories(forIdentifiers: ["dog"]).contains(.pets))
        #expect(SceneCategory.categories(forIdentifiers: ["cat"]).contains(.pets))
    }

    // MARK: Refined categories — "what is this a photo OF"
    //
    // Real device output filed people-photos under Food and Nature, and product
    // boxes and mountains under Documents. These lock the product rules that fix
    // that, working from the same signals the app has cached.

    @Test("A person in the frame vetoes food, nature and documents")
    func facesVetoContentCategories() {
        // Kid eating pizza → the classifier sees pizza, but it's a photo of the kid.
        #expect(!SceneCategory.refined(fromLabels: ["pizza"], hasFaces: true).contains(.food))
        // Family at the beach → sees beach, but it's a photo of the family.
        #expect(!SceneCategory.refined(fromLabels: ["beach"], hasFaces: true).contains(.nature))
        // A person holding a page → not a document photo.
        #expect(!SceneCategory.refined(fromLabels: ["document"], hasFaces: true).contains(.documents))
    }

    @Test("Without faces, content categories still apply")
    func noFacesKeepsCategories() {
        #expect(SceneCategory.refined(fromLabels: ["pizza"], hasFaces: false).contains(.food))
        #expect(SceneCategory.refined(fromLabels: ["sunset"], hasFaces: false).contains(.nature))
        #expect(SceneCategory.refined(fromLabels: ["receipt"], hasFaces: false).contains(.documents))
    }

    @Test("Distant people the face detector missed still veto nature")
    func peopleLabelVetoesNatureWithoutAFace() {
        // The real gap: a person small in a wide scene isn't resolved as a face
        // on the 512px analysis image, so `hasFaces` is false — but the scene
        // classifier still labels the frame "people"/"crowd".
        #expect(!SceneCategory.refined(fromLabels: ["beach", "people"], hasFaces: false).contains(.nature))
        #expect(!SceneCategory.refined(fromLabels: ["mountain", "crowd"], hasFaces: false).contains(.nature))
        #expect(!SceneCategory.refined(fromLabels: ["landscape", "baby"], hasFaces: false).contains(.nature))
    }

    @Test("A people label vetoes food as well")
    func peopleLabelVetoesFood() {
        #expect(!SceneCategory.refined(fromLabels: ["pizza", "child"], hasFaces: false).contains(.food))
    }

    @Test("A pure landscape with no people signal stays nature")
    func pureLandscapeStaysNature() {
        #expect(SceneCategory.refined(fromLabels: ["mountain", "sky", "sunset"], hasFaces: false).contains(.nature))
    }

    @Test("People labels leave pets alone")
    func peopleLabelDoesNotVetoPets() {
        #expect(SceneCategory.refined(fromLabels: ["dog", "person"], hasFaces: false).contains(.pets))
    }

    @Test("Pets survive a person in the frame")
    func facesDoNotVetoPets() {
        // A person holding a cat is still a cat photo.
        #expect(SceneCategory.refined(fromLabels: ["cat"], hasFaces: true).contains(.pets))
    }

    // MARK: Confidence-aware assignment

    private func label(_ id: String, _ confidence: Float) -> ClassificationLabel {
        ClassificationLabel(identifier: id, confidence: confidence)
    }

    @Test("A weak incidental label doesn't override a strong one")
    func weakLabelDoesNotAssignCategory() {
        // The exact real-device case: a document photo the classifier was 90%
        // sure of, carrying a 38% "sky", was landing in Nature.
        let tags = SceneCategory.refined(
            from: [
                label("document", 0.90),
                label("screenshot", 0.90),
                label("outdoor", 0.38),
                label("night_sky", 0.38),
                label("sky", 0.38)
            ],
            hasFaces: false
        )
        #expect(tags.contains(.documents))
        #expect(!tags.contains(.nature), "38% sky must not tag a 90%-document photo as nature")
    }

    @Test("A genuine sunset, where the nature label IS the strong one, stays nature")
    func strongNatureLabelIsKept() {
        let tags = SceneCategory.refined(
            from: [label("sunset", 0.71), label("sky", 0.55), label("ocean", 0.34)],
            hasFaces: false
        )
        #expect(tags.contains(.nature))
    }

    @Test("A stray 20% person can't empty a strong nature scene")
    func strayPeopleLabelDoesNotVetoStrongNature() {
        // Guards the over-veto direction: a 20% "person" is below the people
        // floor (0.25), so an 80%-mountain scene stays Nature.
        let tags = SceneCategory.refined(
            from: [label("mountain", 0.80), label("person", 0.20)],
            hasFaces: false
        )
        #expect(tags.contains(.nature))
    }

    @Test("A weak-but-real people label still vetoes nature")
    func weakPeopleLabelVetoesNatureWhenAboveFloor() {
        // The regression this fixed: a "crowd" that's weak next to a dominant
        // "concert" was being filtered out by the strict category floor before
        // the people check ever saw it, leaving crowds in Nature. People are
        // judged eagerly now — 0.3 is above the people floor even though it's
        // far below the 0.9 top label.
        let tags = SceneCategory.refined(
            from: [label("concert", 0.90), label("stage", 0.60), label("crowd", 0.30)],
            hasFaces: false
        )
        #expect(!tags.contains(.nature))
    }

    @Test("A car photographed against scenery is not nature")
    func vehicleVetoesNature() {
        // Real case: a car shot outdoors picks up "outdoor"/"tree" from behind it.
        #expect(!SceneCategory.refined(
            from: [label("car", 0.85), label("tree", 0.40), label("outdoor", 0.38)],
            hasFaces: false
        ).contains(.nature))
    }

    @Test("A distant car in a vista doesn't strip the vista")
    func weakVehicleDoesNotVetoNature() {
        // Vehicles are judged on the strong labels: a car weak next to a
        // dominant mountain is incidental, and the vista stays Nature.
        let tags = SceneCategory.refined(
            from: [label("mountain", 0.80), label("car", 0.30)],
            hasFaces: false
        )
        #expect(tags.contains(.nature))
    }

    @Test("A nature scene is never a document")
    func natureVetoesDocuments() {
        // The exact real-device error: mountains + a sign filed under Documents.
        let tags = SceneCategory.refined(fromLabels: ["mountain", "text"], hasFaces: false)
        #expect(tags.contains(.nature))
        #expect(!tags.contains(.documents))
    }

    @Test("The packaging-leaking document tokens are gone")
    func packagingTokensNoLongerDocuments() {
        // "book jacket" is Vision's label for a printed box/sleeve — a Nautica
        // bedding box, a fabric-swatch card. It must not read as a document.
        #expect(!SceneCategory.categories(forIdentifiers: ["book jacket"]).contains(.documents))
        #expect(!SceneCategory.categories(forIdentifiers: ["book"]).contains(.documents))
        // A genuine document token still works.
        #expect(SceneCategory.categories(forIdentifiers: ["receipt"]).contains(.documents))
        #expect(SceneCategory.categories(forIdentifiers: ["notebook"]).contains(.documents))
    }

    @Test("Document labels map to .documents")
    func documentMapping() {
        #expect(SceneCategory.categories(forIdentifiers: ["receipt"]).contains(.documents))
        #expect(SceneCategory.categories(forIdentifiers: ["document"]).contains(.documents))
    }

    @Test("Nature labels map to .nature")
    func natureMapping() {
        #expect(SceneCategory.categories(forIdentifiers: ["mountain"]).contains(.nature))
        #expect(SceneCategory.categories(forIdentifiers: ["sunset"]).contains(.nature))
        #expect(SceneCategory.categories(forIdentifiers: ["beach"]).contains(.nature))
    }

    @Test("Generic words no longer misfile ordinary photos as documents")
    func genericWordsDoNotMatchDocuments() {
        // These were once document keywords; a photo of a room matched them and
        // was filed alongside scanned pages.
        for id in ["poster", "sign", "card", "label", "print", "letter", "note"] {
            #expect(!SceneCategory.categories(forIdentifiers: [id]).contains(.documents))
        }
    }

    @Test("Truly unrelated labels map to nothing")
    func noMatch() {
        #expect(SceneCategory.categories(forIdentifiers: ["spreadsheet", "abstract", "pattern"]).isEmpty)
    }

    @Test("Multiple labels accumulate multiple categories")
    func multiple() {
        let tags = SceneCategory.categories(forIdentifiers: ["pizza", "dog"])
        #expect(tags == [.food, .pets])
    }

    @Test("Token matching, not substring (avoids false positives)")
    func tokenMatching() {
        // "category" contains the substring "cat" but should NOT map to pets.
        #expect(!SceneCategory.categories(forIdentifiers: ["category"]).contains(.pets))
    }
}
