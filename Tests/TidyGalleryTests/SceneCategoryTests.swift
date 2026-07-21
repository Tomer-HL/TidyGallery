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
