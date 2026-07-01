//
//  FaceLandmarkEvaluatorTests.swift
//  TidyGalleryTests
//
//  The eyes-open and smile heuristics are derived from geometry, so we feed
//  synthetic landmark points and assert the qualitative behaviour: open eyes
//  score higher than closed, upturned mouths score higher than flat.
//

import Testing
import CoreGraphics
@testable import TidyGallery

@Suite("Face landmark geometry")
struct FaceLandmarkEvaluatorTests {

    // MARK: Eye Aspect Ratio

    @Test("Open eye has higher EAR than a closed (flat) eye")
    func earOpenVsClosed() {
        // Open eye: noticeable vertical opening relative to width.
        let open: [CGPoint] = [
            .init(x: 0.0, y: 0.5),  .init(x: 0.25, y: 0.75),
            .init(x: 0.5, y: 0.8),  .init(x: 0.75, y: 0.75),
            .init(x: 1.0, y: 0.5),  .init(x: 0.5, y: 0.2)
        ]
        // Closed eye: almost a flat line.
        let closed: [CGPoint] = [
            .init(x: 0.0, y: 0.50), .init(x: 0.25, y: 0.51),
            .init(x: 0.5, y: 0.52), .init(x: 0.75, y: 0.51),
            .init(x: 1.0, y: 0.50), .init(x: 0.5, y: 0.49)
        ]
        let earOpen = FaceLandmarkEvaluator.eyeAspectRatio(open)!
        let earClosed = FaceLandmarkEvaluator.eyeAspectRatio(closed)!
        #expect(earOpen > earClosed)
    }

    @Test("Openness score maps EAR into [0,1] with correct ordering")
    func opennessMapping() {
        let closed = FaceLandmarkEvaluator.opennessScore(fromEAR: 0.05)
        let mid = FaceLandmarkEvaluator.opennessScore(fromEAR: 0.20)
        let open = FaceLandmarkEvaluator.opennessScore(fromEAR: 0.35)
        #expect(isClose(closed, 0))
        #expect(isClose(open, 1))
        #expect(mid > closed && mid < open)
    }

    @Test("Too few points returns nil rather than a bogus ratio")
    func earInsufficientPoints() {
        #expect(FaceLandmarkEvaluator.eyeAspectRatio([.init(x: 0, y: 0)]) == nil)
    }

    // MARK: Smile

    @Test("Upturned wide mouth scores higher than a flat one")
    func smileVsNeutral() {
        // Smiling: corners (leftmost/rightmost) sit ABOVE the lip centroid.
        let smiling: [CGPoint] = [
            .init(x: 0.0, y: 0.58), .init(x: 0.25, y: 0.50),
            .init(x: 0.5, y: 0.46), .init(x: 0.75, y: 0.50),
            .init(x: 1.0, y: 0.58), .init(x: 0.5, y: 0.42)
        ]
        // Neutral: corners sit BELOW the centroid (mouth bows downward/flat).
        let neutral: [CGPoint] = [
            .init(x: 0.1, y: 0.50), .init(x: 0.3, y: 0.57),
            .init(x: 0.5, y: 0.59), .init(x: 0.7, y: 0.57),
            .init(x: 0.9, y: 0.50), .init(x: 0.5, y: 0.41)
        ]
        let smile = FaceLandmarkEvaluator.smileScore(outerLips: smiling)!
        let flat = FaceLandmarkEvaluator.smileScore(outerLips: neutral)!
        #expect(smile > flat)
    }

    @Test("Smile score stays within [0,1]")
    func smileBounds() {
        let pts: [CGPoint] = [
            .init(x: 0.0, y: 0.6), .init(x: 0.2, y: 0.3),
            .init(x: 0.5, y: 0.2), .init(x: 0.8, y: 0.3),
            .init(x: 1.0, y: 0.6), .init(x: 0.5, y: 0.5)
        ]
        let score = FaceLandmarkEvaluator.smileScore(outerLips: pts)!
        #expect(score >= 0 && score <= 1)
    }
}
