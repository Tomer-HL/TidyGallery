//
//  FaceQuality.swift
//  TidyGallery
//
//  Value type describing the per-image face assessment derived from
//  `DetectFaceLandmarksRequest`. Vision returns landmark *points*, not
//  booleans, so eyes-open and smiling are computed geometrically here and
//  stored as normalised confidences.
//

import Foundation

/// Aggregated face signal for a single image.
///
/// When an image has multiple faces we keep the *worst* eye-openness and the
/// *best* smile among them, on the intuition that a good group photo wants
/// nobody blinking and at least someone smiling. Tune in `ShotScorer` if the
/// product view differs.
struct FaceQuality: Sendable, Hashable, Codable {

    /// Number of faces Vision detected in the image.
    let faceCount: Int

    /// `0` = clearly closed, `1` = clearly open. Aggregated across faces as the
    /// minimum (so one blinker drags the score down). `nil` when no face.
    let eyesOpenScore: Double?

    /// `0` = neutral/frown, `1` = clear smile. Aggregated as the max across
    /// faces. `nil` when no face.
    let smileScore: Double?

    /// Convenience: a photo with no faces returns a neutral face component so
    /// landscapes aren't penalised for lacking people.
    var hasFaces: Bool { faceCount > 0 }

    /// Combined face component in `[0, 1]`, or `nil` when there are no faces
    /// (caller decides how to treat face-less images).
    var combinedScore: Double? {
        guard hasFaces else { return nil }
        let eyes = eyesOpenScore ?? 0.5
        let smile = smileScore ?? 0.5
        // Eyes-open matters more than smiling for "is this a usable shot".
        return eyes * 0.65 + smile * 0.35
    }

    static let noFaces = FaceQuality(faceCount: 0, eyesOpenScore: nil, smileScore: nil)
}
