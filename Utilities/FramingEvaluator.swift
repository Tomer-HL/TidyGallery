//
//  FramingEvaluator.swift
//  TidyGallery
//
//  Turns a face's bounding box into a "is this person well placed in the
//  frame?" score.
//
//  Two distinct defects, deliberately not averaged into one vague number:
//
//    1. CLIPPING — the face runs off the edge of the picture. This is a real
//       defect. Between two otherwise identical shots, the one with somebody's
//       head half out of frame is the worse photograph, and it is the single
//       most common reason a burst member is unusable after blinking.
//
//    2. PLACEMENT — how far the subject sits from a pleasing position. Centre
//       and the rule-of-thirds lines both read as deliberate; halfway between
//       them reads as an accident. This is a preference, not a defect, so it
//       moves the score far less than clipping does.
//
//  Pure geometry on normalised rectangles: no Vision types, no UIKit, no
//  Photos. The scoring rule is the thing worth testing, and it should be
//  provable without a device or a photo library.
//
//  Coordinate space: Vision's, i.e. normalised [0,1] with the ORIGIN AT THE
//  BOTTOM-LEFT. Nothing here is vertically asymmetric, so the flip relative to
//  UIKit doesn't affect the result — but it matters if this ever grows a
//  "headroom above the subject" rule, which is not symmetric at all.
//

import CoreGraphics
import Foundation

enum FramingEvaluator {

    /// How much of the face may sit outside the frame before the score reaches
    /// zero, as a fraction of the face's own size.
    ///
    /// Not zero-tolerance: Vision's boxes routinely extend a little past the
    /// edge on a face that is comfortably inside the picture, so treating any
    /// overhang at all as a defect would penalise perfectly good photos.
    private static let clipTolerance = 0.35

    /// Framing score in `[0, 1]` for a single face.
    ///
    /// - Parameter box: the face's bounding box in normalised Vision
    ///   coordinates.
    static func score(faceBox box: CGRect) -> Double? {
        guard box.width > 0, box.height > 0 else { return nil }

        return clippingScore(box) * 0.75 + placementScore(box) * 0.25
    }

    /// `1` when the face is fully inside the frame, falling to `0` as it runs
    /// off the edge.
    ///
    /// Measured against the face's own size rather than the frame's, so a
    /// close-up and a distant face are judged by the same standard: losing a
    /// third of someone's head is equally bad whichever it is.
    static func clippingScore(_ box: CGRect) -> Double {
        let overhang = max(
            max(-box.minX, 0) + max(box.maxX - 1, 0),   // horizontal
            max(-box.minY, 0) + max(box.maxY - 1, 0)    // vertical
        )
        guard overhang > 0 else { return 1 }

        let allowance = max(box.width, box.height) * clipTolerance
        guard allowance > 0 else { return 0 }
        return max(0, 1 - overhang / allowance)
    }

    /// `1` at a compositionally natural position, falling off with distance
    /// from the nearest of them.
    ///
    /// The targets are the centre and the four rule-of-thirds intersections.
    /// Rewarding the *nearest* target rather than the centre alone matters:
    /// an off-centre portrait is a normal photograph, and scoring it as badly
    /// placed would have this quietly prefer mugshots.
    static func placementScore(_ box: CGRect) -> Double {
        let centre = CGPoint(x: box.midX, y: box.midY)
        let third = 1.0 / 3.0

        let targets = [
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: third, y: third),
            CGPoint(x: third, y: 2 * third),
            CGPoint(x: 2 * third, y: third),
            CGPoint(x: 2 * third, y: 2 * third)
        ]

        let nearest = targets
            .map { hypot(centre.x - $0.x, centre.y - $0.y) }
            .min() ?? 0

        // Distance from a target to the farthest corner of the frame, used to
        // normalise. Beyond that the score is 0, which no in-frame face reaches.
        let worstCase = hypot(0.5, 0.5)
        return max(0, 1 - Double(nearest) / Double(worstCase))
    }
}
