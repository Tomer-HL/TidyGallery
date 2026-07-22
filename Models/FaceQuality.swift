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
/// Aggregation across faces is chosen per signal, because the right answer
/// differs: **worst** eye-openness (one blinker ruins a group shot),
/// **average** smile (most people smiling beats one person smiling), and
/// **worst** framing (a face clipped at the edge is a defect regardless of who
/// else is well placed).
struct FaceQuality: Sendable, Hashable, Codable {

    /// Number of faces Vision detected in the image.
    let faceCount: Int

    /// `0` = clearly closed, `1` = clearly open. Aggregated across faces as the
    /// minimum (so one blinker drags the score down). `nil` when no face.
    let eyesOpenScore: Double?

    /// `0` = neutral/frown, `1` = clear smile. Aggregated as the **mean** across
    /// faces. `nil` when no face.
    ///
    /// Was the maximum, which meant a group shot with one person grinning
    /// scored the same as one where everybody was. For choosing between
    /// near-identical shots of the same group — which is the only thing this
    /// score is ever used for — the mean is the question actually being asked.
    let smileScore: Double?

    /// Apple's own per-face capture-quality metric, averaged across faces.
    /// `nil` when unavailable.
    ///
    /// From `VNDetectFaceCaptureQualityRequest`, and worth more than the
    /// geometry above: it is a trained model rather than hand-rolled landmark
    /// arithmetic, and it folds in exposure, blur and expression together.
    ///
    /// Apple documents these scores as comparable only between images **of the
    /// same subject**. That is normally a serious limitation; here it is the
    /// exact use case, since the only comparison ever made is within one
    /// duplicate stack. It should not be compared across stacks, which is why
    /// it contributes to the composite rather than replacing it.
    let captureQuality: Double?

    /// How well subjects sit in the frame. `0` = a face cut off at the edge,
    /// `1` = comfortably inside it. Aggregated as the minimum. `nil` when no
    /// face.
    let framingScore: Double?

    /// Defaults on the two newer signals, so every call site doesn't have to
    /// name them.
    ///
    /// Written out rather than relying on the memberwise initialiser because an
    /// optional `let` gets no implicit default — only an optional `var` does —
    /// so adding these fields would otherwise have broken every existing
    /// construction. `nil` is also the honest value: it means "not measured",
    /// and `combinedScore` redistributes the weight rather than substituting a
    /// number nobody computed.
    init(
        faceCount: Int,
        eyesOpenScore: Double?,
        smileScore: Double?,
        captureQuality: Double? = nil,
        framingScore: Double? = nil
    ) {
        self.faceCount = faceCount
        self.eyesOpenScore = eyesOpenScore
        self.smileScore = smileScore
        self.captureQuality = captureQuality
        self.framingScore = framingScore
    }

    /// Convenience: a photo with no faces returns a neutral face component so
    /// landscapes aren't penalised for lacking people.
    var hasFaces: Bool { faceCount > 0 }

    /// Combined face component in `[0, 1]`, or `nil` when there are no faces
    /// (caller decides how to treat face-less images).
    ///
    /// Weights, and why.
    ///
    /// Eyes-open stays dominant because a blink is the one thing here that
    /// makes a shot *unusable* rather than merely worse — every other signal is
    /// a matter of degree. Capture quality is next: Apple's trained judgement of
    /// the same face across shots, and where it disagrees with the hand-rolled
    /// geometry it is usually the one to believe. Smile and framing are
    /// preferences, so they order shots that are otherwise equivalent without
    /// overturning a defect.
    ///
    /// The eye weight is 0.45 rather than the 0.40 that would have made the four
    /// numbers tidy, and that is deliberate. Before capture quality and framing
    /// existed, eyes carried 0.65 of a two-signal blend; adding signals dilutes
    /// it arithmetically even though nothing about blinking got less important.
    /// At 0.40 a blinking face with everything else perfect scored 0.59 against
    /// 0.62 for an open-eyed face that was mediocre otherwise — technically the
    /// right order, by a margin too thin to trust. 0.45 restores the gap.
    ///
    /// Missing signals redistribute rather than defaulting to 0.5. A face whose
    /// lips Vision couldn't resolve should be judged on what *was* measured,
    /// not dragged toward the middle by a stand-in number.
    var combinedScore: Double? {
        guard hasFaces else { return nil }

        var sum = 0.0
        var weight = 0.0
        func add(_ value: Double?, _ w: Double) {
            guard let value else { return }
            sum += value * w
            weight += w
        }

        add(eyesOpenScore, 0.45)
        add(captureQuality, 0.30)
        add(smileScore, 0.15)
        add(framingScore, 0.10)

        guard weight > 0 else { return 0.5 }   // faces found, nothing measurable
        return sum / weight
    }

    static let noFaces = FaceQuality(
        faceCount: 0,
        eyesOpenScore: nil,
        smileScore: nil,
        captureQuality: nil,
        framingScore: nil
    )
}
