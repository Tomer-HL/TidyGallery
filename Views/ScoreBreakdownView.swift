//
//  ScoreBreakdownView.swift
//  TidyGallery
//
//  Shows why a photo is being surfaced: the metric bars the engine scored it on,
//  plus plain-language reasons (and, inside a duplicate group, how it compares
//  to the best shot).
//
//  PERFORMANCE NOTE: everything here is computed lazily for ONE photo when the
//  user opens this sheet. It reads a `ShotScore` that was already computed and
//  cached during analysis, and does only arithmetic — no Vision, no Photos
//  requests, no I/O. Grids never build this, so scanning and scrolling a large
//  library are completely unaffected.
//

import SwiftUI

struct ScoreBreakdownView: View {
    let score: ShotScore
    /// The group's best shot, when this photo sits in a duplicate stack and
    /// isn't the winner. `nil` for standalone categories.
    var bestShotScore: ShotScore?
    var isBestShot: Bool = false
    let config: AnalysisConfiguration

    @Environment(\.dismiss) private var dismiss

    private var reasons: [ScoreExplanation.Reason] {
        ScoreExplanation.reasons(for: score, comparedToBest: bestShotScore, config: config)
    }

    var body: some View {
        NavigationStack {
            List {
                if isBestShot {
                    Section {
                        Label("This is the best shot in its group", systemImage: "star.fill")
                            .foregroundStyle(Theme.Colors.best)
                            .font(.headline)
                    }
                }

                Section("What we noticed") {
                    ForEach(reasons) { reason in
                        Label {
                            Text(reason.text)
                        } icon: {
                            Image(systemName: reason.systemImage)
                                .foregroundStyle(color(for: reason.tone))
                        }
                    }
                }

                Section("How it scored") {
                    ForEach(ScoreExplanation.metrics(for: score)) { metric in
                        metricRow(metric)
                    }
                }

                Section {
                    LabeledContent("Overall") {
                        Text(percent(score.composite(using: config)))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    if let bestShotScore, !isBestShot {
                        LabeledContent("Best shot") {
                            Text(percent(bestShotScore.composite(using: config)))
                                .monospacedDigit()
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                } footer: {
                    Text("Scores combine sharpness, face quality and aesthetics. They rank photos within a group — they aren't a verdict on the photo.")
                }
            }
            .navigationTitle("Why this photo?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.Colors.accent)
    }

    // MARK: Pieces

    @ViewBuilder
    private func metricRow(_ metric: ScoreExplanation.Metric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.name)
                Spacer()
                if let value = metric.value {
                    Text(percent(value)).fontWeight(.semibold).monospacedDigit()
                } else {
                    Text(metric.unavailableNote ?? "—")
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .font(.subheadline)
                }
            }
            if let value = metric.value {
                ProgressView(value: max(0, min(1, value)))
                    .tint(barColor(for: value))
            }
        }
        .padding(.vertical, 2)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func color(for tone: ScoreExplanation.Reason.Tone) -> Color {
        switch tone {
        case .positive: Theme.Colors.best
        case .caution: Theme.Colors.destructive
        case .neutral: Theme.Colors.textSecondary
        }
    }

    private func barColor(for value: Double) -> Color {
        value < 0.35 ? Theme.Colors.destructive : Theme.Colors.accent
    }
}
