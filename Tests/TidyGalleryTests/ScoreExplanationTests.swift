//
//  ScoreExplanationTests.swift
//  TidyGalleryTests
//
//  The explanation is what the user reads before deleting a photo, so the
//  wording must follow from the numbers — never contradict them.
//

import Testing
import Foundation
@testable import TidyGallery

@Suite("Score explanations")
struct ScoreExplanationTests {

    private let config = AnalysisConfiguration.default

    private func score(
        sharpness: Double = 0.8,
        aesthetics: Double? = 0.5,
        faces: FaceQuality = .noFaces,
        favorite: Bool = false
    ) -> ShotScore {
        ShotScore(sharpness: sharpness, aesthetics: aesthetics, faceQuality: faces, isFavorite: favorite)
    }

    private func texts(_ reasons: [ScoreExplanation.Reason]) -> [String] {
        reasons.map(\.text)
    }

    @Test("A favorite is called out as protected")
    func favoriteCalledOut() {
        let reasons = ScoreExplanation.reasons(for: score(favorite: true), config: config)
        #expect(reasons.contains { $0.text.contains("Favourite") })
        #expect(reasons.contains { $0.tone == .positive })
    }

    @Test("Closed eyes are reported")
    func closedEyesReported() {
        let faces = FaceQuality(faceCount: 1, eyesOpenScore: 0.1, smileScore: 0.8)
        let reasons = ScoreExplanation.reasons(for: score(faces: faces), config: config)
        #expect(reasons.contains { $0.text.lowercased().contains("eyes look closed") })
    }

    @Test("Wording adapts to how many people are in the photo")
    func wordingAdaptsToFaceCount() {
        let single = FaceQuality(faceCount: 1, eyesOpenScore: 0.1, smileScore: 0.8)
        let group = FaceQuality(faceCount: 4, eyesOpenScore: 0.1, smileScore: 0.8)

        #expect(texts(ScoreExplanation.reasons(for: score(faces: single), config: config))
            .contains { $0.hasPrefix("Their eyes") })
        #expect(texts(ScoreExplanation.reasons(for: score(faces: group), config: config))
            .contains { $0.hasPrefix("Someone's eyes") })
    }

    @Test("Face observations are never invented for a photo with no faces")
    func noFaceClaimsWithoutFaces() {
        let reasons = texts(ScoreExplanation.reasons(for: score(faces: .noFaces), config: config))
        #expect(!reasons.contains { $0.lowercased().contains("eyes") })
        #expect(!reasons.contains { $0.lowercased().contains("smil") })
    }

    @Test("A soft photo is described as soft")
    func softnessReported() {
        let reasons = texts(ScoreExplanation.reasons(for: score(sharpness: 0.05), config: config))
        #expect(reasons.contains { $0.contains("soft or out of focus") })
    }

    // MARK: Comparison against the best shot

    @Test("A clearly worse photo is described as clearly worse")
    func clearlyWorseThanBest() {
        let best = score(sharpness: 0.95, aesthetics: 0.9)
        let loser = score(sharpness: 0.2, aesthetics: 0.2)
        let reasons = texts(ScoreExplanation.reasons(for: loser, comparedToBest: best, config: config))

        #expect(reasons.contains { $0.contains("Softer than the best shot") })
        #expect(reasons.contains { $0.contains("Clearly lower quality") })
    }

    @Test("A near-tie is described as close, not as clearly worse")
    func nearTieIsHonest() {
        let best = score(sharpness: 0.82, aesthetics: 0.5)
        let almost = score(sharpness: 0.80, aesthetics: 0.5)
        let reasons = texts(ScoreExplanation.reasons(for: almost, comparedToBest: best, config: config))

        #expect(reasons.contains { $0.contains("Very close in quality") })
        #expect(!reasons.contains { $0.contains("Clearly lower quality") })
    }

    @Test("Eye comparison only fires when both photos have faces")
    func eyeComparisonNeedsBothFaces() {
        let best = score(faces: FaceQuality(faceCount: 1, eyesOpenScore: 0.9, smileScore: 0.5))
        let loser = score(faces: .noFaces)
        let reasons = texts(ScoreExplanation.reasons(for: loser, comparedToBest: best, config: config))
        #expect(!reasons.contains { $0.contains("Eyes are more open") })
    }

    @Test("There is always at least one reason to show")
    func neverEmpty() {
        #expect(!ScoreExplanation.reasons(for: score(), config: config).isEmpty)
    }

    // MARK: Metrics

    @Test("Missing metrics are labelled rather than shown as zero")
    func unavailableMetricsExplained() {
        let metrics = ScoreExplanation.metrics(
            for: score(aesthetics: nil, faces: .noFaces)
        )
        let aesthetics = try! #require(metrics.first { $0.name == "Aesthetics" })
        let faces = try! #require(metrics.first { $0.name == "Face quality" })

        #expect(aesthetics.value == nil)
        #expect(aesthetics.unavailableNote != nil)
        #expect(faces.value == nil)
        #expect(faces.unavailableNote == "No faces detected")
    }

    @Test("Sharpness is always reported")
    func sharpnessAlwaysPresent() {
        let metrics = ScoreExplanation.metrics(for: score(sharpness: 0.42))
        #expect(metrics.first { $0.name == "Sharpness" }?.value == 0.42)
    }
}
