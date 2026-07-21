//
//  SettingsScreen.swift
//  TidyGallery
//
//  Tune detection sensitivity on-device. Every control maps to one knob in
//  `AnalysisConfiguration` via `TuningSettings`.
//
//  The screen makes one distinction explicit, because it changes how long
//  applying takes: most settings are used while *deriving* categories, so they
//  re-apply instantly against photos already analysed. Scene confidence and
//  selfie sensitivity are baked in during analysis, so changing them discards
//  the cache and re-scans the library.
//

import SwiftUI

struct SettingsScreen: View {
    /// Current saved settings.
    let current: TuningSettings
    /// Called with the new settings when the user applies them.
    var onApply: (TuningSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: TuningSettings

    init(current: TuningSettings, onApply: @escaping (TuningSettings) -> Void) {
        self.current = current
        self.onApply = onApply
        _draft = State(initialValue: current)
    }

    private var needsRescan: Bool {
        draft.requiresReanalysis(comparedTo: current)
    }

    private var hasChanges: Bool { draft != current }

    var body: some View {
        NavigationStack {
            Form {
                duplicatesSection
                blurrySection
                bigFilesSection
                analysisSection
                resetSection
            }
            .navigationTitle("Detection settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                    .disabled(!hasChanges)
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.Colors.accent)
    }

    // MARK: Sections

    private var duplicatesSection: some View {
        Section {
            slider(
                value: Binding(
                    get: { Double(draft.duplicateSimilarity) },
                    set: { draft.duplicateSimilarity = Float($0) }
                ),
                range: 0.20...0.50,
                step: 0.01,
                valueLabel: String(format: "%.2f", draft.duplicateSimilarity)
            )
        } header: {
            Text("Duplicate sensitivity")
        } footer: {
            Text("How alike two photos must look to be grouped. Lower groups only very close matches; higher groups photos that merely share a composition.")
        }
    }

    private var blurrySection: some View {
        Section {
            slider(
                value: $draft.blurryPercentile,
                range: 0.05...0.30,
                step: 0.01,
                valueLabel: "\(Int(draft.blurryPercentile * 100))%"
            )
        } header: {
            Text("Possibly blurry")
        } footer: {
            Text("At most this share of your library can be flagged as soft. Raise it to see more candidates, lower it to see only the worst.")
        }
    }

    private var bigFilesSection: some View {
        Section {
            slider(
                value: $draft.bigFileMinMB,
                range: 1...25,
                step: 1,
                valueLabel: "\(Int(draft.bigFileMinMB)) MB"
            )
        } header: {
            Text("Big files")
        } footer: {
            Text("Minimum size for a photo to count as a big file.")
        }
    }

    private var analysisSection: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Content detection").font(.subheadline)
                slider(
                    value: Binding(
                        get: { Double(draft.sceneConfidence) },
                        set: { draft.sceneConfidence = Float($0) }
                    ),
                    range: 0.01...0.30,
                    step: 0.01,
                    valueLabel: String(format: "%.2f", draft.sceneConfidence)
                )
            }
            VStack(alignment: .leading) {
                Text("Selfie sensitivity").font(.subheadline)
                slider(
                    value: $draft.selfieFaceArea,
                    range: 0.04...0.30,
                    step: 0.01,
                    valueLabel: "\(Int(draft.selfieFaceArea * 100))% of frame"
                )
            }
            Toggle("Analyse iCloud photos", isOn: $draft.analyseICloudPhotos)
            Text("Photos stored only in iCloud can't be analysed without downloading them. Left off, they're skipped rather than judged from a low-quality preview — which would report sharp photos as blurry. Turning this on uses network data.")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.textSecondary)

            if needsRescan {
                Label(
                    "Changing these re-scans your library, which takes a while.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.footnote)
                .foregroundStyle(Theme.Colors.best)
            }
        } header: {
            Text("Requires a re-scan")
        } footer: {
            Text("Content detection sets how confident the classifier must be before tagging Food, Pets, Documents and so on — lower catches more. Selfie sensitivity is how much of the frame a face must fill. These are computed while analysing, so changing them re-analyses your photos.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset to defaults", role: .destructive) {
                draft = .default
            }
            .disabled(draft == .default)
        }
    }

    // MARK: Slider row

    private func slider(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: String
    ) -> some View {
        VStack(spacing: 2) {
            Slider(value: value, in: range, step: step)
            HStack {
                Text(String(format: "%g", range.lowerBound))
                Spacer()
                Text(valueLabel).fontWeight(.semibold).monospacedDigit()
                Spacer()
                Text(String(format: "%g", range.upperBound))
            }
            .font(.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
        }
    }
}
