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


    /// Whether analysis may download photos stored only in iCloud.
    ///
    /// Off by default: it uses network and potentially cellular data. When off,
    /// iCloud-only photos are skipped rather than analysed from a degraded
    /// thumbnail, which would misreport sharpness and break duplicate matching.
    var analyseICloudPhotos: Bool

    static let `default` = TuningSettings(
        duplicateSimilarity: AnalysisConfiguration.default.featurePrintSimilarityThreshold,
        blurryPercentile: AnalysisConfiguration.default.blurryPercentile,
        bigFileMinMB: Double(AnalysisConfiguration.default.bigFileMinBytes) / 1_000_000,
        sceneConfidence: AnalysisConfiguration.default.sceneClassificationMinConfidence,
        analyseICloudPhotos: false
    )

    /// Overlay these choices onto the full configuration.
    func applied(to base: AnalysisConfiguration = .default) -> AnalysisConfiguration {
        var config = base
        config.featurePrintSimilarityThreshold = duplicateSimilarity
        config.blurryPercentile = blurryPercentile
        config.bigFileMinBytes = Int64(bigFileMinMB * 1_000_000)
        config.sceneClassificationMinConfidence = sceneConfidence
        return config
    }

    /// Whether moving from `other` to `self` invalidates cached analysis.
    ///
    /// Most knobs are applied while *deriving* categories, so they take effect
    /// immediately with no re-analysis. These two are baked in during analysis
    /// (classification and face geometry run once per photo and are cached), so
    /// changing them means the cache must be discarded and photos re-analysed.
    /// Changing these makes cached results *wrong*, so the cache must be
    /// discarded — they were baked into every stored analysis.
    func requiresCachePurge(comparedTo other: TuningSettings) -> Bool {
        sceneConfidence != other.sceneConfidence
    }

    func requiresReanalysis(comparedTo other: TuningSettings) -> Bool {
        sceneConfidence != other.sceneConfidence
            // Turning iCloud analysis on must re-scan so previously-skipped
            // photos are picked up.
            || analyseICloudPhotos != other.analyseICloudPhotos
    }

    // MARK: - Tolerant decoding

    private enum CodingKeys: String, CodingKey {
        case duplicateSimilarity, blurryPercentile, bigFileMinMB
        case sceneConfidence, analyseICloudPhotos
    }

    init(
        duplicateSimilarity: Float,
        blurryPercentile: Double,
        bigFileMinMB: Double,
        sceneConfidence: Float,
        analyseICloudPhotos: Bool
    ) {
        self.duplicateSimilarity = duplicateSimilarity
        self.blurryPercentile = blurryPercentile
        self.bigFileMinMB = bigFileMinMB
        self.sceneConfidence = sceneConfidence
        self.analyseICloudPhotos = analyseICloudPhotos
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
        analyseICloudPhotos = try container.decodeIfPresent(Bool.self, forKey: .analyseICloudPhotos)
            ?? fallback.analyseICloudPhotos
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
