//
//  TuningSettings.swift
//  TidyGallery
//
//  The user-facing subset of `AnalysisConfiguration` — the handful of knobs the
//  Settings screen exposes, persisted between launches.
//
//  Why a separate type instead of persisting `AnalysisConfiguration` wholesale?
//  The full configuration has many internal tunables that change as the pipeline
//  evolves. Encoding all of them would mean a saved blob breaks (and the user's
//  choices silently reset) every time a new field is added. Persisting only the
//  exposed knobs keeps saved settings stable, and decoding is tolerant of
//  missing keys so even this set can grow safely.
//

import Foundation

struct TuningSettings: Codable, Equatable, Sendable {

    /// Max feature-print distance for two photos to count as near-duplicates.
    /// Lower = stricter grouping.
    var duplicateSimilarity: Float

    /// Fraction of the library eligible for "Possibly blurry". Higher = more
    /// photos surfaced.
    var blurryPercentile: Double

    /// Minimum size (megabytes) for a photo to count as a "big file".
    var bigFileMinMB: Double

    /// Confidence floor for a Vision label to be trusted. Lower = more photos
    /// land in the content categories (Food, Pets, …).
    var sceneConfidence: Float

    /// Fraction of the frame the largest face must fill for a selfie. Lower =
    /// more photos counted as selfies.
    var selfieFaceArea: Double

    static let `default` = TuningSettings(
        duplicateSimilarity: AnalysisConfiguration.default.featurePrintSimilarityThreshold,
        blurryPercentile: AnalysisConfiguration.default.blurryPercentile,
        bigFileMinMB: Double(AnalysisConfiguration.default.bigFileMinBytes) / 1_000_000,
        sceneConfidence: AnalysisConfiguration.default.sceneClassificationMinConfidence,
        selfieFaceArea: AnalysisConfiguration.default.selfieMinFaceAreaFraction
    )

    /// Overlay these choices onto the full configuration.
    func applied(to base: AnalysisConfiguration = .default) -> AnalysisConfiguration {
        var config = base
        config.featurePrintSimilarityThreshold = duplicateSimilarity
        config.blurryPercentile = blurryPercentile
        config.bigFileMinBytes = Int64(bigFileMinMB * 1_000_000)
        config.sceneClassificationMinConfidence = sceneConfidence
        config.selfieMinFaceAreaFraction = selfieFaceArea
        return config
    }

    /// Whether moving from `other` to `self` invalidates cached analysis.
    ///
    /// Most knobs are applied while *deriving* categories, so they take effect
    /// immediately with no re-analysis. These two are baked in during analysis
    /// (classification and face geometry run once per photo and are cached), so
    /// changing them means the cache must be discarded and photos re-analysed.
    func requiresReanalysis(comparedTo other: TuningSettings) -> Bool {
        sceneConfidence != other.sceneConfidence
            || selfieFaceArea != other.selfieFaceArea
    }

    // MARK: - Tolerant decoding

    private enum CodingKeys: String, CodingKey {
        case duplicateSimilarity, blurryPercentile, bigFileMinMB
        case sceneConfidence, selfieFaceArea
    }

    init(
        duplicateSimilarity: Float,
        blurryPercentile: Double,
        bigFileMinMB: Double,
        sceneConfidence: Float,
        selfieFaceArea: Double
    ) {
        self.duplicateSimilarity = duplicateSimilarity
        self.blurryPercentile = blurryPercentile
        self.bigFileMinMB = bigFileMinMB
        self.sceneConfidence = sceneConfidence
        self.selfieFaceArea = selfieFaceArea
    }

    /// Any missing key falls back to the default, so adding a knob later never
    /// wipes what the user has already chosen.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TuningSettings.default
        duplicateSimilarity = try container.decodeIfPresent(Float.self, forKey: .duplicateSimilarity)
            ?? fallback.duplicateSimilarity
        blurryPercentile = try container.decodeIfPresent(Double.self, forKey: .blurryPercentile)
            ?? fallback.blurryPercentile
        bigFileMinMB = try container.decodeIfPresent(Double.self, forKey: .bigFileMinMB)
            ?? fallback.bigFileMinMB
        sceneConfidence = try container.decodeIfPresent(Float.self, forKey: .sceneConfidence)
            ?? fallback.sceneConfidence
        selfieFaceArea = try container.decodeIfPresent(Double.self, forKey: .selfieFaceArea)
            ?? fallback.selfieFaceArea
    }
}

/// Loads and saves `TuningSettings` in `UserDefaults`.
enum TuningStore {

    private static let key = "tidygallery.tuningSettings"

    static func load() -> TuningSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(TuningSettings.self, from: data)
        else { return .default }
        return settings
    }

    static func save(_ settings: TuningSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
