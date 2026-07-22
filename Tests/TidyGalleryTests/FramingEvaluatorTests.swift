//
//  FramingEvaluatorTests.swift
//  TidyGalleryTests
//
//  Framing feeds best-shot selection, so getting it wrong means recommending
//  the deletion of the better photograph. Pure geometry, so it can be pinned
//  exactly — no device, no Vision, no photo library.
//
//  Coordinate space throughout is Vision's: normalised, origin bottom-left.
//

import Testing
import CoreGraphics
@testable import TidyGallery

@Suite("Framing evaluator")
struct FramingEvaluatorTests {

    /// A face comfortably inside the frame, centred.
    private let centred = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)

    // MARK: Clipping — the part that is a real defect

    @Test("A face fully inside the frame is not clipped")
    func insideIsUnclipped() {
        #expect(FramingEvaluator.clippingScore(centred) == 1)
        #expect(FramingEvaluator.clippingScore(CGRect(x: 0.01, y: 0.01, width: 0.2, height: 0.2)) == 1)
    }

    @Test("A face running off the edge scores lower the more of it is lost")
    func clippingScalesWithOverhang() {
        let slightly = CGRect(x: -0.02, y: 0.4, width: 0.2, height: 0.2)
        let badly = CGRect(x: -0.06, y: 0.4, width: 0.2, height: 0.2)

        let slightScore = FramingEvaluator.clippingScore(slightly)
        let badScore = FramingEvaluator.clippingScore(badly)

        #expect(slightScore < 1)
        #expect(badScore < slightScore)
        #expect(badScore >= 0)
    }

    @Test("Overhang is judged against the face's own size, not the frame's")
    func clippingIsScaleInvariant() {
        // Both lose the same PROPORTION of the face. A close-up and a distant
        // face should be judged by the same standard — losing a third of
        // someone's head is equally bad either way.
        let bigFace = CGRect(x: -0.05, y: 0.3, width: 0.50, height: 0.50)
        let smallFace = CGRect(x: -0.01, y: 0.3, width: 0.10, height: 0.10)

        let big = FramingEvaluator.clippingScore(bigFace)
        let small = FramingEvaluator.clippingScore(smallFace)
        #expect(abs(big - small) < 0.0001)
    }

    @Test("Clipping is detected on every edge")
    func clippingOnAllEdges() {
        for box in [
            CGRect(x: -0.05, y: 0.4, width: 0.2, height: 0.2),   // left
            CGRect(x: 0.85, y: 0.4, width: 0.2, height: 0.2),    // right
            CGRect(x: 0.4, y: -0.05, width: 0.2, height: 0.2),   // bottom
            CGRect(x: 0.4, y: 0.85, width: 0.2, height: 0.2)     // top
        ] {
            #expect(FramingEvaluator.clippingScore(box) < 1)
        }
    }

    @Test("A box just touching the edge is not treated as a defect")
    func touchingEdgeIsFine() {
        // Vision's boxes routinely sit flush against the edge on a face that is
        // comfortably in shot. Penalising that would mark good photos down.
        #expect(FramingEvaluator.clippingScore(CGRect(x: 0, y: 0, width: 0.3, height: 0.3)) == 1)
    }

    // MARK: Placement — a preference, not a defect

    @Test("Centre and the rule-of-thirds points both score well")
    func naturalPositionsScoreWell() {
        let third = 1.0 / 3.0
        let atCentre = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        let atThird = CGRect(x: third - 0.05, y: third - 0.05, width: 0.1, height: 0.1)

        #expect(FramingEvaluator.placementScore(atCentre) > 0.9)
        // An off-centre portrait is a normal photograph, not a mistake. If this
        // ever fails, the scorer has started preferring mugshots.
        #expect(FramingEvaluator.placementScore(atThird) > 0.9)
    }

    @Test("A subject wedged into a corner scores worse than a placed one")
    func cornerScoresWorse() {
        let corner = CGRect(x: 0.0, y: 0.0, width: 0.08, height: 0.08)
        let centre = CGRect(x: 0.46, y: 0.46, width: 0.08, height: 0.08)
        #expect(FramingEvaluator.placementScore(corner) < FramingEvaluator.placementScore(centre))
    }

    // MARK: Combined

    @Test("A well-framed face scores near the top")
    func wellFramedScoresHigh() {
        let score = FramingEvaluator.score(faceBox: centred)
        #expect((score ?? 0) > 0.9)
    }

    @Test("Clipping outweighs placement")
    func clippingDominates() {
        // A centred but clipped face must score worse than an off-centre but
        // whole one. Losing part of someone's head is a defect; being off
        // centre is a preference, and the weights have to say so.
        let clippedButCentred = CGRect(x: 0.4, y: -0.08, width: 0.2, height: 0.2)
        let wholeButOffCentre = CGRect(x: 0.06, y: 0.72, width: 0.14, height: 0.14)

        #expect((FramingEvaluator.score(faceBox: clippedButCentred) ?? 1)
                < (FramingEvaluator.score(faceBox: wholeButOffCentre) ?? 0))
    }

    @Test("A degenerate box yields no opinion rather than a wrong one")
    func degenerateBoxIsNil() {
        #expect(FramingEvaluator.score(faceBox: .zero) == nil)
        #expect(FramingEvaluator.score(faceBox: CGRect(x: 0.5, y: 0.5, width: 0, height: 0.2)) == nil)
    }

    @Test("Every score stays inside [0, 1]")
    func scoresAreBounded() {
        for box in [
            centred,
            CGRect(x: -0.5, y: -0.5, width: 0.3, height: 0.3),   // mostly outside
            CGRect(x: 0.9, y: 0.9, width: 0.4, height: 0.4),
            CGRect(x: 0, y: 0, width: 1, height: 1)              // fills the frame
        ] {
            guard let score = FramingEvaluator.score(faceBox: box) else { continue }
            #expect(score >= 0 && score <= 1)
        }
    }
}
