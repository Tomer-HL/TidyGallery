//
//  CalibrationReport.swift
//  TidyGalleryTests
//
//  A calibration harness, not a pass/fail test. It runs the REAL analysis
//  pipeline over a folder of sample images and prints a report to the console
//  (visible in the CI "Run tests" log — search it for "CALIBRATION REPORT").
//
//  How to use
//  ----------
//  1. Drop a handful of representative photos into `Tests/CalibrationImages/`.
//     Name them with a group prefix before the first underscore so the report
//     can tell you whether same-group photos really do score as similar, e.g.:
//        beach_1.heic  beach_2.heic  beach_3.heic   (one burst)
//        dog_1.jpg     dog_2.jpg                    (another burst)
//        sunset.jpg                                 (a standalone)
//  2. Push. Read the report in the CI log.
//  3. Adjust the constants in `AnalysisConfiguration` and repeat.
//
//  The report is the ground truth for picking:
//    • featurePrintSimilarityThreshold  (clustering)
//    • preselectSimilarityThreshold     (deletion suggestion)
//    • the blur half-saturation constant in BlurDetector
//
//  If the folder has no images the harness prints a notice and returns — it
//  never fails the build.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import TidyGallery

/// Anchor class so we can locate the test bundle that holds the images.
private final class BundleToken {}

@Suite("Calibration (prints a report, never fails)")
struct CalibrationReport {

    private let config = AnalysisConfiguration.default

    @Test("Analyse sample images and print tuning data")
    func calibrate() async throws {
        let urls = Self.sampleImageURLs()
        guard !urls.isEmpty else {
            print("""
            \n=== TIDYGALLERY CALIBRATION REPORT ===
            No images found in the test bundle. Add photos to Tests/CalibrationImages/
            (named like beach_1.heic, beach_2.heic, dog_1.jpg ...) and push again.
            === END REPORT ===\n
            """)
            return
        }

        let analyzer = ImageAnalyzer()

        // Analyse every image. All get the SAME creation date so they land in a
        // single time bucket — this isolates the VISUAL similarity threshold,
        // which is the subtle one. (The time window is a separate, simple knob.)
        let sharedDate = Date(timeIntervalSince1970: 0)
        var assets: [PhotoAsset] = []
        var names: [PhotoAsset.ID: String] = [:]
        var lapVar: [PhotoAsset.ID: Double] = [:]

        var failures: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            // Downsample to ~512px — matches what the app feeds Vision, and
            // avoids decoding 40MB+ full-res frames on the simulator.
            guard let cgImage = Self.loadImage(url, maxPixel: 512) else {
                failures.append("\(name) (decode failed)")
                continue
            }
            do {
                let analyzed = try await analyzer.analyze(image: cgImage, isFavorite: false)
                let asset = PhotoAsset(
                    id: name,                   // filename as id for readable output
                    creationDate: sharedDate,
                    modificationDate: sharedDate,
                    pixelWidth: cgImage.width,
                    pixelHeight: cgImage.height,
                    isFavorite: false,
                    coordinate: nil,
                    featurePrint: analyzed.featurePrint,
                    score: analyzed.score
                )
                assets.append(asset)
                names[asset.id] = name
                lapVar[asset.id] = BlurDetector.laplacianVariance(of: cgImage) ?? 0
            } catch {
                failures.append("\(name) (\(error))")
            }
        }
        if !failures.isEmpty {
            print("⚠️ skipped \(failures.count) image(s): \(failures.joined(separator: ", "))")
        }
        guard !assets.isEmpty else {
            print("\n=== TIDYGALLERY CALIBRATION REPORT ===\nAll images failed to analyse.\n=== END REPORT ===\n")
            return
        }

        printReport(assets: assets, lapVar: lapVar)
    }

    // MARK: - Report

    /// Pad a string to a fixed column width for readable tables.
    private func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
    /// Format a Double to N places (single-argument String(format:) is safe).
    private func f(_ x: Double, _ places: Int = 2) -> String {
        String(format: "%.\(places)f", x)
    }

    private func printReport(assets: [PhotoAsset], lapVar: [PhotoAsset.ID: Double]) {
        var out = "\n=== TIDYGALLERY CALIBRATION REPORT ===\n"
        out += "Config: burstWindow=\(f(config.burstTimeWindow, 0))s"
        out += "  simThreshold=\(f(Double(config.featurePrintSimilarityThreshold)))"
        out += "  preselectSim=\(f(Double(config.preselectSimilarityThreshold)))"
        out += "  qualityMargin=\(f(config.preselectQualityMargin))\n"

        // 0. Feature-print sanity — if these vectors are all-zero or identical
        //    across different photos, the embedding model isn't running (e.g.
        //    the iOS Simulator doesn't execute VNGenerateImageFeaturePrint).
        out += "\n--- Feature-print sanity ---\n"
        if let first = assets.first?.featurePrint {
            out += "  vector length: \(first.vector.count)\n"
            let sample = first.vector.prefix(6).map { f(Double($0), 4) }.joined(separator: ", ")
            out += "  img[0] first values: \(sample)\n"
        }
        if assets.count > 1, let v = assets[1].featurePrint {
            let sample = v.vector.prefix(6).map { f(Double($0), 4) }.joined(separator: ", ")
            out += "  img[1] first values: \(sample)\n"
        }
        if let f0 = assets.first?.featurePrint {
            let allSame = assets.allSatisfy { ($0.featurePrint?.vector ?? []) == f0.vector }
            let allZero = f0.vector.allSatisfy { $0 == 0 }
            out += "  all vectors identical across images? \(allSame)\n"
            out += "  img[0] vector is all-zero? \(allZero)\n"
        }

        // 1. Per-image scores.
        out += "\n--- Per-image scores (higher = better, except lapVar which is raw) ---\n"
        out += pad("name", 22) + pad("sharp", 9) + pad("lapVar", 10)
            + pad("faces", 6) + pad("eyesOpen", 9) + pad("smile", 7) + "composite\n"
        for asset in assets {
            guard let s = asset.score else { continue }
            let eyes = s.faceQuality.eyesOpenScore.map { f($0) } ?? "-"
            let smile = s.faceQuality.smileScore.map { f($0) } ?? "-"
            out += pad(asset.id, 22)
                + pad(f(s.sharpness), 9)
                + pad(f(lapVar[asset.id] ?? 0, 0), 10)
                + pad("\(s.faceQuality.faceCount)", 6)
                + pad(eyes, 9)
                + pad(smile, 7)
                + f(s.composite(using: config), 3) + "\n"
        }

        // 2. Pairwise feature-print distances — closest pairs are what matter
        //    for choosing a threshold, so we show only the N smallest plus a
        //    distribution summary (the full list can be thousands of pairs).
        var samePairs: [Double] = []
        var diffPairs: [Double] = []
        var lines: [(Double, String)] = []
        var allDistances: [Double] = []

        for i in 0..<assets.count {
            for j in (i + 1)..<assets.count {
                guard let a = assets[i].featurePrint, let b = assets[j].featurePrint else { continue }
                let d = Double(a.distance(to: b))
                allDistances.append(d)
                let sameGroup = Self.group(of: assets[i].id) == Self.group(of: assets[j].id)
                if sameGroup { samePairs.append(d) } else { diffPairs.append(d) }
                let verdict = Double(config.featurePrintSimilarityThreshold) >= d ? "SIMILAR" : "different"
                let line = "  " + pad(assets[i].id, 16) + " <-> " + pad(assets[j].id, 16)
                    + "  " + f(d, 3) + "  => " + verdict
                lines.append((d, line))
            }
        }
        let sortedLines = lines.sorted { $0.0 < $1.0 }
        let cap = 45
        out += "\n--- Closest pairs (smaller = more similar; likely duplicates at the top) ---\n"
        out += "  (showing \(min(cap, sortedLines.count)) of \(sortedLines.count) total pairs)\n"
        for (_, line) in sortedLines.prefix(cap) { out += line + "\n" }

        // Distance distribution — lets a threshold be chosen even without group labels.
        let sd = allDistances.sorted()
        if !sd.isEmpty {
            func pct(_ p: Double) -> Double { sd[min(sd.count - 1, Int(p * Double(sd.count)))] }
            out += "\n--- Distance distribution ---\n"
            out += "  min=\(f(sd.first!, 3))  p05=\(f(pct(0.05), 3))  p10=\(f(pct(0.10), 3))"
            out += "  median=\(f(pct(0.50), 3))  max=\(f(sd.last!, 3))\n"
            out += "  A natural gap between a cluster of small distances and the rest\n"
            out += "  is where the similarity threshold belongs.\n"
        }

        // 3. Stacks at current thresholds.
        out += "\n--- Stacks at current thresholds ---\n"
        let clusters = StackBuilder(config: config).cluster(assets)
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let stacks = ShotScorer(config: config).makeStacks(from: clusters, assetsByID: byID)
        if stacks.isEmpty {
            out += "  (no multi-photo stacks formed at these thresholds)\n"
        }
        for (n, stack) in stacks.enumerated() {
            out += "  Stack \(n + 1):\n"
            for id in stack.rankedAssetIDs {
                var marks: [String] = []
                if id == stack.bestShotID { marks.append("★BEST") }
                if stack.assetsPreselectedForDeletion.contains(id) { marks.append("preselect-delete") }
                out += "    - \(id) \(marks.joined(separator: " "))\n"
            }
        }

        // 4. Threshold guidance from the ground-truth groups.
        out += "\n--- Suggested threshold ---\n"
        if let maxSame = samePairs.max(), let minDiff = diffPairs.min() {
            out += "  Largest same-group distance : \(f(maxSame, 3))\n"
            out += "  Smallest diff-group distance: \(f(minDiff, 3))\n"
            if maxSame < minDiff {
                let mid = (maxSame + minDiff) / 2
                out += "  ✅ Clean separation. Set featurePrintSimilarityThreshold ≈ \(f(mid)) (midpoint).\n"
            } else {
                out += "  ⚠️ Groups overlap — no single threshold cleanly separates them.\n"
                out += "     Consider a tighter time window, or accept some mis-grouping.\n"
            }
        } else {
            out += "  Need at least one same-group pair AND one diff-group pair for guidance.\n"
            out += "  Add more images using the group-prefix naming (e.g. beach_1, beach_2).\n"
        }
        out += "=== END REPORT ===\n"

        print(out)
    }

    // MARK: - Helpers

    private static func group(of name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        if let underscore = base.firstIndex(of: "_") {
            return String(base[..<underscore])
        }
        return base
    }

    private static func sampleImageURLs() -> [URL] {
        let bundle = Bundle(for: BundleToken.self)
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
        // Enumerate ALL bundled resources and match extension case-INsensitively
        // so iPhone's uppercase ".JPG" files are found too.
        let all = bundle.urls(forResourcesWithExtension: nil, subdirectory: nil) ?? []
        return all
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Loads a downsampled `CGImage` (thumbnail) at ~maxPixel on the long edge —
    /// matches the resolution the app feeds Vision and avoids huge decodes.
    private static func loadImage(_ url: URL, maxPixel: Int = 512) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
