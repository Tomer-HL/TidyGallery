//
//  ScoreExplanation.swift
//  TidyGallery
//
//  Turns a `ShotScore` into plain-language reasons a photo is being surfaced,
//  and — inside a duplicate group — why it lost to the best shot.
//
//  The engine already computes everything needed (sharpness, eyes-open, smile,
//  aesthetics, composite); until now the UI threw it away and the user just had
//  to trust the recommendation. Keeping this pure means the wording is testable
//  and the view stays dumb.
//

import Foundation

struct ScoreExplanation {

    /// One human-readable observation about a photo.
    struct Reason: Identifiable, Equatable, Sendable {
        enum Tone: Sendable { case positive, caution, neutral }

        let text: String
        let systemImage: String
        let tone: Tone

        var id: String { text }
    }

    // Thresholds for *describing* a photo. These only affect wording, never
    // whether something is deleted, so they're kept local and readable.
    private static let eyesClosedBelow = 0.5
    private static let notSmilingBelow = 0.3
    private static let meaningfulSharpnessGap = 0.10
    private static let meaningfulEyesGap = 0.15

    /// Reasons for a photo, optionally compared against its group's best shot.
    ///
    /// - Parameters:
    ///   - score: the photo's own breakdown.
    ///   - best: the best shot's breakdown, when the photo sits in a duplicate
    ///     group and isn't itself the winner. `nil` for standalone categories.
    ///   - config: supplies the same margins the scorer uses, so the explanation
    ///     agrees with the decision.
    static func reasons(
        for score: ShotScore,
        comparedToBest best: ShotScore? = nil,
        config: AnalysisConfiguration = .default
    ) -> [Reason] {
        var reasons: [Reason] = []

        if score.isFavorite {
            reasons.append(
                Reason(
                    text: "Favourite — never suggested for deletion",
                    systemImage: "heart.fill",
                    tone: .positive
                )
            )
        }

        // Face observations are the most concrete thing we can say.
        if score.faceQuality.hasFaces {
            if let eyes = score.faceQuality.eyesOpenScore, eyes < eyesClosedBelow {
                reasons.append(
                    Reason(
                        text: score.faceQuality.faceCount > 1
                            ? "Someone's eyes look closed"
                            : "Their eyes look closed",
                        systemImage: "eye.slash",
                        tone: .caution
                    )
                )
            }
            if let smile = score.faceQuality.smileScore, smile < notSmilingBelow {
                reasons.append(
                    Reason(text: "Nobody's smiling", systemImage: "face.dashed", tone: .neutral)
                )
            }
        }

        if score.sharpness <= config.blurrySinglesSharpnessCeiling {
            reasons.append(
                Reason(text: "Looks soft or out of focus", systemImage: "camera.metering.none", tone: .caution)
            )
        }

        // Comparison against the group's winner.
        if let best {
            if best.sharpness - score.sharpness >= meaningfulSharpnessGap {
                reasons.append(
                    Reason(text: "Softer than the best shot", systemImage: "arrow.down.right", tone: .caution)
                )
            }
            if let bestEyes = best.faceQuality.eyesOpenScore,
               let eyes = score.faceQuality.eyesOpenScore,
               bestEyes - eyes >= meaningfulEyesGap {
                reasons.append(
                    Reason(text: "Eyes are more open in the best shot", systemImage: "eye", tone: .caution)
                )
            }

            let gap = best.composite(using: config) - score.composite(using: config)
            if gap >= config.preselectQualityMargin {
                reasons.append(
                    Reason(text: "Clearly lower quality than the best shot", systemImage: "chart.line.downtrend.xyaxis", tone: .caution)
                )
            } else if gap > 0 {
                reasons.append(
                    Reason(text: "Very close in quality to the best shot", systemImage: "equal.circle", tone: .neutral)
                )
            }
        }

        if reasons.isEmpty {
            reasons.append(
                Reason(text: "Nothing stands out — yours to judge", systemImage: "hand.raised", tone: .neutral)
            )
        }
        return reasons
    }

    /// The metric bars shown alongside the reasons.
    struct Metric: Identifiable, Sendable {
        let name: String
        /// `nil` when the metric doesn't apply (e.g. faces in a landscape).
        let value: Double?
        let unavailableNote: String?

        var id: String { name }
    }

    static func metrics(for score: ShotScore) -> [Metric] {
        [
            Metric(name: "Sharpness", value: score.sharpness, unavailableNote: nil),
            Metric(
                name: "Aesthetics",
                value: score.aesthetics,
                unavailableNote: score.aesthetics == nil ? "Not available" : nil
            ),
            Metric(
                name: "Face quality",
                value: score.faceQuality.combinedScore,
                unavailableNote: score.faceQuality.hasFaces ? nil : "No faces detected"
            )
        ]
    }
}
