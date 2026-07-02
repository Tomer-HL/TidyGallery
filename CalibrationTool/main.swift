//
//  main.swift
//  CalibrationTool  (macOS command-line target)
//
//  Runs the REAL analysis pipeline over a folder of images and prints a tuning
//  report. This exists because `VNGenerateImageFeaturePrintRequest` does not
//  execute on the iOS Simulator (it returns near-constant vectors) — but it
//  works natively on macOS, which is exactly what the CI runner is. So we run
//  calibration here, on the Mac, where the embeddings are real.
//
//  The tool shares the app's analysis sources (ImageAnalyzer, BlurDetector,
//  StackBuilder, ShotScorer, and the models) — they're compiled directly into
//  this target, so no import is needed.
//
//  Usage:  CalibrationTool [path-to-image-folder]
//          (defaults to ./Tests/CalibrationImages)
//

import Foundation
import CoreGraphics
import ImageIO

// MARK: - Formatting helpers

private func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

private func f(_ x: Double, _ places: Int = 2) -> String {
    String(format: "%.\(places)f", x)
}

// MARK: - Image loading (downsampled to match what the app feeds Vision)

private func loadImage(path: String, maxPixel: Int = 512) -> CGImage? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
}

// MARK: - Report

private func makeReport(assets: [PhotoAsset], lapVar: [String: Double], config: AnalysisConfiguration) -> String {
    var out = "\n=== TIDYGALLERY CALIBRATION REPORT (native macOS) ===\n"
    out += "Config: burstWindow=\(f(config.burstTimeWindow, 0))s"
    out += "  simThreshold=\(f(Double(config.featurePrintSimilarityThreshold)))"
    out += "  preselectSim=\(f(Double(config.preselectSimilarityThreshold)))"
    out += "  qualityMargin=\(f(config.preselectQualityMargin))\n"

    // 0. Feature-print sanity.
    out += "\n--- Feature-print sanity ---\n"
    if let first = assets.first?.featurePrint {
        out += "  vector length: \(first.vector.count)\n"
        out += "  img[0] first values: \(first.vector.prefix(6).map { f(Double($0), 4) }.joined(separator: ", "))\n"
    }
    if assets.count > 1, let v = assets[1].featurePrint {
        out += "  img[1] first values: \(v.vector.prefix(6).map { f(Double($0), 4) }.joined(separator: ", "))\n"
    }

    // 1. Per-image scores.
    out += "\n--- Per-image scores ---\n"
    out += pad("name", 18) + pad("sharp", 8) + pad("lapVar", 9)
        + pad("faces", 6) + pad("eyesOpen", 9) + pad("smile", 7) + "composite\n"
    for asset in assets {
        guard let s = asset.score else { continue }
        let eyes = s.faceQuality.eyesOpenScore.map { f($0) } ?? "-"
        let smile = s.faceQuality.smileScore.map { f($0) } ?? "-"
        out += pad(asset.id, 18)
            + pad(f(s.sharpness), 8)
            + pad(f(lapVar[asset.id] ?? 0, 0), 9)
            + pad("\(s.faceQuality.faceCount)", 6)
            + pad(eyes, 9)
            + pad(smile, 7)
            + f(s.composite(using: config), 3) + "\n"
    }

    // 2. Closest pairs + distance distribution.
    var lines: [(Double, String)] = []
    var allDistances: [Double] = []
    for i in 0..<assets.count {
        for j in (i + 1)..<assets.count {
            guard let a = assets[i].featurePrint, let b = assets[j].featurePrint else { continue }
            let d = Double(a.distance(to: b))
            allDistances.append(d)
            let verdict = Double(config.featurePrintSimilarityThreshold) >= d ? "SIMILAR" : "different"
            lines.append((d, "  " + pad(assets[i].id, 16) + " <-> " + pad(assets[j].id, 16)
                          + "  " + f(d, 3) + "  => " + verdict))
        }
    }
    let sorted = lines.sorted { $0.0 < $1.0 }
    let cap = 60
    out += "\n--- Closest pairs (smaller = more similar; likely duplicates at top) ---\n"
    out += "  (showing \(min(cap, sorted.count)) of \(sorted.count) total pairs)\n"
    for (_, line) in sorted.prefix(cap) { out += line + "\n" }

    let sd = allDistances.sorted()
    if !sd.isEmpty {
        func pct(_ p: Double) -> Double { sd[min(sd.count - 1, Int(p * Double(sd.count)))] }
        out += "\n--- Distance distribution ---\n"
        out += "  min=\(f(sd.first!, 3))  p05=\(f(pct(0.05), 3))  p10=\(f(pct(0.10), 3))"
        out += "  p25=\(f(pct(0.25), 3))  median=\(f(pct(0.50), 3))  max=\(f(sd.last!, 3))\n"
        out += "  The similarity threshold belongs in the gap between the cluster of\n"
        out += "  small distances (real duplicates) and the rest.\n"
    }

    // 3. Stacks at current thresholds (all images share a time bucket here).
    out += "\n--- Stacks at current thresholds ---\n"
    let clusters = StackBuilder(config: config).cluster(assets)
    let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    let stacks = ShotScorer(config: config).makeStacks(from: clusters, assetsByID: byID)
    if stacks.isEmpty { out += "  (no multi-photo stacks formed)\n" }
    for (n, stack) in stacks.enumerated() {
        out += "  Stack \(n + 1):\n"
        for id in stack.rankedAssetIDs {
            var marks: [String] = []
            if id == stack.bestShotID { marks.append("★BEST") }
            if stack.assetsPreselectedForDeletion.contains(id) { marks.append("preselect-delete") }
            out += "    - \(id) \(marks.joined(separator: " "))\n"
        }
    }
    out += "=== END REPORT ===\n"
    return out
}

// MARK: - Entry point

@main
struct CalibrationTool {
    static func main() async {
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/CalibrationImages"
        let config = AnalysisConfiguration.default
        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
            print("Could not read directory: \(dir)")
            return
        }
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
        let files = entries
            .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        guard !files.isEmpty else {
            print("No images found in \(dir) (looked for jpg/jpeg/png/heic/heif).")
            return
        }

        let analyzer = ImageAnalyzer()
        let sharedDate = Date(timeIntervalSince1970: 0)
        var assets: [PhotoAsset] = []
        var lapVar: [String: Double] = [:]
        var failures: [String] = []

        for name in files {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let cg = loadImage(path: path, maxPixel: 512) else {
                failures.append("\(name) (decode failed)")
                continue
            }
            do {
                let analyzed = try await analyzer.analyze(image: cg, isFavorite: false)
                assets.append(PhotoAsset(
                    id: name,
                    creationDate: sharedDate,
                    modificationDate: sharedDate,
                    pixelWidth: cg.width,
                    pixelHeight: cg.height,
                    isFavorite: false,
                    coordinate: nil,
                    featurePrint: analyzed.featurePrint,
                    score: analyzed.score
                ))
                lapVar[name] = BlurDetector.laplacianVariance(of: cg) ?? 0
            } catch {
                failures.append("\(name) (\(error))")
            }
        }

        if !failures.isEmpty {
            print("⚠️ skipped \(failures.count) image(s): \(failures.joined(separator: ", "))")
        }
        guard !assets.isEmpty else {
            print("All images failed to analyse.")
            return
        }

        print(makeReport(assets: assets, lapVar: lapVar, config: config))
    }
}
