//
//  FaceLandmarkEvaluator.swift
//  TidyGallery
//
//  Turns Vision face-landmark *points* into eyes-open and smiling *scores*.
//  Vision does not expose these as booleans, so we compute them geometrically:
//
//  - Eyes open  →  Eye Aspect Ratio (EAR): the eye's vertical opening relative
//    to its horizontal width. Low EAR ≈ closed/blinking.
//  - Smiling    →  Mouth curvature + aspect: corners of the mouth raised
//    relative to the lip centre, and a wider-than-tall mouth.
//
//  These are heuristics. They're intentionally conservative and only used as
//  one weighted signal among several, and always compared within a stack.
//

import Foundation
import CoreGraphics

/// Pure geometry helpers operating on normalised landmark points (0...1,
/// Vision's coordinate space). Kept free of Vision types so it's unit-testable
/// with synthetic points.
enum FaceLandmarkEvaluator {

    /// Eye Aspect Ratio for a set of eye contour points. Returns a value where
    /// larger = more open. Typical open eyes ~0.25–0.35, closed <0.12.
    ///
    /// - Parameter eyePoints: ordered contour points around one eye.
    static func eyeAspectRatio(_ eyePoints: [CGPoint]) -> Double? {
        guard eyePoints.count >= 4 else { return nil }

        // Horizontal extent = width between the two most-separated points on X.
        let xs = eyePoints.map(\.x)
        let ys = eyePoints.map(\.y)
        let width = (xs.max()! - xs.min()!)
        let height = (ys.max()! - ys.min()!)
        guard width > 0 else { return nil }
        return Double(height / width)
    }

    /// Maps a raw EAR to a `[0,1]` openness confidence via a soft threshold.
    static func opennessScore(fromEAR ear: Double) -> Double {
        // Below ~0.12 treat as closed, above ~0.28 as fully open, smooth between.
        let closed = 0.12, open = 0.28
        let clamped = min(max(ear, closed), open)
        return (clamped - closed) / (open - closed)
    }

    /// Smile score in `[0,1]` from outer-lip contour points.
    ///
    /// Heuristic: mouth corners sitting HIGHER (smaller Y in image space where
    /// origin is bottom-left, so we compare against the vertical lip centre) and
    /// a wide mouth indicate a smile. We combine corner-lift with width/height
    /// aspect.
    static func smileScore(outerLips: [CGPoint]) -> Double? {
        guard outerLips.count >= 6 else { return nil }

        let xs = outerLips.map(\.x)
        let ys = outerLips.map(\.y)
        let leftCornerX = xs.min()!
        let rightCornerX = xs.max()!
        let mouthWidth = rightCornerX - leftCornerX
        let mouthHeight = ys.max()! - ys.min()!
        guard mouthWidth > 0, mouthHeight > 0 else { return nil }

        // Corner points: the landmark points nearest the min/max X.
        let leftCorner = outerLips.min(by: { $0.x < $1.x })!
        let rightCorner = outerLips.max(by: { $0.x < $1.x })!
        let cornerAvgY = Double((leftCorner.y + rightCorner.y) / 2)
        let centreY = Double(ys.reduce(0, +) / CGFloat(ys.count))

        // In Vision's normalised space, Y increases upward. Corners above the
        // centroid (cornerAvgY > centreY) => upturned => smiling.
        let lift = (cornerAvgY - centreY) / Double(mouthHeight) // roughly [-1, 1]
        let liftScore = min(max((lift + 0.15) / 0.5, 0), 1)     // recentre & clamp

        // Wider mouths (smiles) have higher width:height ratio.
        let aspect = Double(mouthWidth / mouthHeight)
        let aspectScore = min(max((aspect - 2.0) / 3.0, 0), 1)

        return liftScore * 0.6 + aspectScore * 0.4
    }
}
