# TidyGallery — Phase 1: Core Architecture & Image Analysis

On-device, privacy-first photo cleanup for iOS 18+. This phase delivers the architecture, data models, and analysis engine. No UI beyond a minimal runnable driver, and **nothing is ever deleted without explicit user confirmation** — deletion lives behind a single, unused-until-Phase-2 method.

## Locked decisions

| Decision | Choice |
|---|---|
| Min iOS | 18.0 (new async Vision API + built-in aesthetics score) |
| Architecture | MVVM + services, analysis on a dedicated `actor` |
| Face analysis | Full: eyes-open (EAR) + smile geometry in Phase 1 |
| Persistence | SwiftData cache, delta re-analysis via change observer |
| Favorites | **Hard lock** — never pre-selected for deletion |
| Stacks | Session-aware near-duplicates: visual match within a 30-min window, bounded by an N-neighbour lookahead (not just ~10s bursts) |
| Stack visibility | Every 2+ group is shown for review, even when nothing is confidently pre-selected |
| Pre-selection | Conservative — only clearly-inferior near-duplicates are pre-checked |
| Big files | Real on-disk size floor (~5 MB), measured on a bounded candidate pool |
| Possibly blurry | Relative: below an absolute ceiling **and** in the library's softest percentile, capped |

## Project structure

```
TidyGallery/
├── App/
│   └── TidyGalleryApp.swift          Composition root, ModelContainer, driver view
├── Models/
│   ├── AnalysisConfiguration.swift   All tunable thresholds/weights in one place
│   ├── FeaturePrint.swift            Sendable embedding + L2 distance / cosine
│   ├── FaceQuality.swift             Eyes-open / smile aggregation
│   ├── ShotScore.swift               Explainable per-image quality breakdown
│   ├── PhotoAsset.swift              Sendable snapshot of a PHAsset (+ results)
│   └── PhotoStack.swift              A cluster + best shot + preselection
├── Persistence/
│   ├── CachedAnalysis.swift          @Model, keyed by localIdentifier
│   └── AnalysisCacheStore.swift      @ModelActor gateway (returns value types)
├── Services/
│   ├── PhotoLibraryService.swift     Auth, paged fetch, thumbnails, deletion
│   ├── PhotoLibraryChangeObserver.swift  Delta events as AsyncStream
│   ├── ImageAnalyzer.swift           actor: feature print, blur, faces, aesthetics
│   ├── StackBuilder.swift            Time-gate → visual refine → union-find
│   ├── ShotScorer.swift              Best-shot election + safe preselection
│   └── LibraryScanCoordinator.swift  @Observable orchestrator the UI watches
└── Utilities/
    ├── BlurDetector.swift            Variance-of-Laplacian via Accelerate
    └── FaceLandmarkEvaluator.swift   EAR + mouth-curvature geometry (pure)
```

## How the grill points were addressed

- **Time-gate before visual clustering.** `StackBuilder` buckets by `creationDate` first (~10s gaps), collapsing the naive O(n²) ≈ 400M-comparison problem on a 20k library into many tiny buckets, then compares feature prints only *within* a bucket.
- **Uses the native distance metric.** `FeaturePrint.distance(to:)` is L2 (smaller = more similar), matching `FeaturePrintObservation.distance(to:)` semantics; thresholds are named constants in `AnalysisConfiguration`, not magic numbers.
- **OOM is located correctly.** Feature prints are tiny; the real cost is image decode. We request ~512px thumbnails, analyse in pages of 200 with only 4 concurrent decodes, and release each image immediately.
- **Blur is relative, not absolute.** Laplacian variance is content-dependent, so `ShotScorer` only ever compares sharpness *between photos in the same stack*.
- **Faces are computed, not assumed.** Vision returns landmark points; `FaceLandmarkEvaluator` derives eyes-open (Eye Aspect Ratio) and smile (corner-lift + mouth aspect) as `[0,1]` confidences.
- **Swift 6 strict concurrency.** No `PHAsset`/`VNObservation` ever crosses an actor boundary. We snapshot assets into `Sendable` value types and re-resolve live `PHAsset`s by `localIdentifier` on the `@MainActor` library service only when pixels are needed. Analysis is an `actor`; cache access is a `@ModelActor`.
- **Persistence + deltas.** `AnalysisCacheStore` upserts by `localIdentifier` + `modificationDate`; `PhotoLibraryChangeObserver` reports inserts/updates/removals so re-scans touch only the delta.
- **Favorite = hard lock.** Enforced in `ShotScorer` *and* defensively in `PhotoStack.init`, which strips the best shot from any deletion set.
- **Limited access handled.** `.limited` still scans the permitted subset; `.denied`/`.restricted` surface a distinct state.

## Scoring model

Composite ∈ [0,1] = weighted sum of sharpness (0.40), face quality (0.35), aesthetics (0.25). When an image has no faces, the face weight is redistributed so landscapes aren't penalised. Favorites get a small +0.05 tiebreak toward winning best shot, but that is separate from the hard deletion lock.

Pre-selection requires **both** gates: near-duplicate of the winner (`distance ≤ 0.35`) **and** clearly worse (`scoreGap ≥ 0.15`). Otherwise the photo is kept.

## ⚠️ Symbols to verify against your Xcode SDK

`ImageAnalyzer` targets the **new Swift Vision API** shipped with iOS 18. These symbol names are new and post-date general availability — confirm them in Xcode, as spelling shifted across betas:

- `GenerateImageFeaturePrintRequest` → `FeaturePrintObservation` (`.data`, `.elementCount`)
- `CalculateImageAestheticsScoresRequest` → `.overallScore` (−1…1)
- `DetectFaceLandmarksRequest` → face observations with `.landmarks`, regions exposing `.normalizedPoints`

If any differ, the classic `VNImageRequestHandler` + `VNGenerateImageFeaturePrintRequest` API is a drop-in fallback and the surrounding value-type design is unchanged. All three requests are wrapped in `do/catch` (aesthetics and faces degrade to neutral), so a mismatch fails compilation loudly rather than misbehaving at runtime.

## Info.plist

Add `NSPhotoLibraryUsageDescription` (e.g. "TidyGallery analyses your photos on-device to suggest duplicates to clean up."). No add-usage key needed.

## Running the tests for free, without a Mac

You don't need a Mac (or an Apple Developer account) to run the test suite — a
free GitHub Actions macOS runner does it. macOS minutes are **unlimited on
public repositories**.

1. Create a **public** repo on GitHub.
2. From this folder (install Git for Windows if needed):
   ```bash
   git init
   git add .
   git commit -m "TidyGallery Phase 1"
   git branch -M main
   git remote add origin https://github.com/<you>/TidyGallery.git
   git push -u origin main
   ```
3. Open the repo's **Actions** tab. The `iOS Tests` workflow runs automatically
   on every push: it installs XcodeGen, generates the project from
   `project.yml`, and runs the suite on an iPhone 16 simulator. Green check = all
   tests pass. The `.xcresult` bundle is uploaded as an artifact for inspection.

The project file itself is generated from `project.yml` (never committed), so
there's nothing to wire by hand. On a Mac you'd run the same two commands:
`brew install xcodegen && xcodegen generate`, then open `TidyGallery.xcodeproj`.

### Getting the app onto your iPhone (later, still free)
Running the *tests* is free above. Running the *app* on your phone with no Mac
means building the `.ipa` in CI and side-loading it with **AltStore** (its
helper runs on Windows) using a free Apple ID — which must be re-signed every 7
days. It's fiddly; TestFlight is the smooth path but needs the $99/yr program.
Not required to keep developing.

## Calibrating the thresholds

The default constants in `AnalysisConfiguration` (`0.55`/`0.35` similarity, the
blur half-saturation) are starting guesses. The `CalibrationTool` macOS target
tunes them against real photos, and runs in the same free CI.

**Why a macOS tool and not a test?** `VNGenerateImageFeaturePrintRequest` does
not execute on the iOS Simulator — it returns near-constant embeddings, so every
photo looks identical. It works natively on macOS, and the CI runner *is* a Mac,
so calibration runs there as a command-line tool (`CalibrationTool/main.swift`).

1. Put sample photos in `Tests/CalibrationImages/` (any case, `.JPG`/`.HEIC`/…).
   See that folder's README for a good sample set — and the **privacy note**,
   since a public repo makes committed images public.
2. Push. Open the CI run → **Run calibration report** step (near the end).
3. It prints per-image scores, the closest feature-print pairs, and a distance
   distribution (min/percentiles/max). The similarity threshold belongs in the
   gap between the tight cluster of duplicate distances and the rest.
4. Edit the constants in `Models/AnalysisConfiguration.swift`, push, repeat.

The iOS test suite (`TidyGalleryTests`) still runs on the simulator and covers
all the pure logic; only the Vision-embedding calibration needs the macOS tool.

## Run it on your iPhone (free, no Mac)

CI builds an **unsigned** `.ipa`; you sign and install it on your phone with a
**free Apple ID** — no Mac, no $99 developer account. Caveats up front: the app
expires after **7 days** (re-install to refresh), a free Apple ID allows **3
sideloaded apps** at once, and the tooling needs Apple's **iTunes + iCloud**
(download from apple.com, *not* the Microsoft Store versions) for the device
drivers.

**1. Get the build.** Actions tab → **Build IPA (unsigned)** → Run workflow (or
use the latest run) → when green, open the run → **Artifacts** → download
`TidyGallery-ipa` → unzip to get `TidyGallery-unsigned.ipa`.

**2. Install a sideload tool (pick one):**
- **Sideloadly** (simplest for a one-off) — sideloadly.io. Plug in your iPhone,
  drag the `.ipa` in, enter your Apple ID, click **Start**. Done.
- **AltStore** (auto-refreshes so it doesn't expire while your PC is on the same
  Wi-Fi) — altstore.io. Install AltServer on Windows, then AltStore on the phone,
  then add the `.ipa` from within AltStore.

**3. Trust the certificate.** On the iPhone: Settings → General → **VPN & Device
Management** → tap your Apple ID → **Trust**.

**4. Launch TidyGallery.** It'll ask for photo access on first run — that's the
`NSPhotoLibraryUsageDescription` prompt. Then tap **Scan my library**.

If a step fails (Apple ID two-factor, driver issues, "app not available"),
that's usually the sideload tool, not the build — the `.ipa` in the artifact is
the same one either tool signs.

## Built so far

Phase 1 (engine): batch fetch, feature-print clustering with time-gating,
blur/face/aesthetics scoring, calibrated thresholds, SwiftData cache, and
incremental re-scan via a change observer.

Phase 2 (UI): stack cards with filmstrips, star best-shot and pre-selected
duplicates, full-screen zoomable preview, reclaimable-storage estimates, and
confirmation-gated deletion.

Phase 3 (more categories): the home is now a CleanMy®Phone-style category
overview (`CleanupHomeView`) rather than a tab bar, since there are now six
cleanup categories. "Duplicates" keeps the best-shot review flow; five
standalone categories share one reusable grid screen (`AssetCleanupScreen`):

- **Large videos** — every video, sorted largest-file-first, with duration.
- **Big files** — Live Photos plus the largest stills. Reading real on-disk
  size for a whole library is expensive, so the candidate pool is bounded to
  Live Photos + the highest-resolution stills, and only those are measured.
- **Screen recordings** — detected heuristically (iOS has no public smart-album
  subtype) via ReplayKit's `RPReplay…` filename prefix; degrades to empty.
- **Possibly blurry** — standalone soft shots, flagged by an *absolute*
  sharpness gate. Because Laplacian variance is content-dependent, this is a
  **surfacing-only** category: items are shown for review and are **never**
  pre-selected, so a false positive costs a glance, not a photo.
- **Screenshots** — as before, now on the shared screen.

Safety is unchanged: none of the standalone categories pre-select anything. The
user multi-selects and confirms, and deletion still routes through the single
`PhotoLibraryService.deleteAssets` path (which also triggers the system's own
confirmation sheet). Favorites remain hard-locked out of duplicate pre-selection
and out of the blurry list. New category thresholds live in
`AnalysisConfiguration`; new files are picked up automatically by XcodeGen's
directory globs, so `project.yml` needs no edits.

Phase 4 (smart content categories): on-device scene classification via Vision's
`VNClassifyImageRequest` (no third-party services) adds **Food**, **Pets**,
**Documents**, and **Nature & scenery** categories. Confident labels are folded
into `SceneCategory` cases (`Models/SceneCategory.swift`) by whole-word token
matching, computed once in `ImageAnalyzer` alongside the feature print and cached
with the rest of the analysis. **Selfies** use a different on-device signal —
face geometry: a photo is tagged a selfie when its largest detected face
(`VNFaceObservation.boundingBox`) fills at least a configurable fraction of the
frame, so close-up portraits are caught while group/scene shots with small
distant faces are not. The cache carries a `schemaVersion` (`CachedAnalysis`):
bumping it (now v3) makes already-analysed photos re-run once so they back-fill
their scene tags instead of staying uncategorised. The SwiftData container build is now resilient
— a migration failure wipes the disposable cache and retries (finally falling
back to in-memory) rather than crashing on launch. The classifier runs on still
images only; these categories are surfacing-only, like the rest.

Phase 5 (storage dashboard): the home now opens with a summary card showing how
much space is reclaimable (`StorageSummary`, computed by the coordinator by
measuring real on-disk sizes for the bounded space-heavy sets — pre-selected
duplicates, videos, big files, recordings — de-duplicated so an asset in two
categories isn't summed twice), with a per-category byte breakdown. Below it the
categories are grouped into sections: **Reclaim space** (Duplicates, Large
videos, Big files, Screen recordings), **Clutter** (Screenshots, Possibly
blurry), and **By content** (Food, Pets, Documents, Nature, Selfies). The summary
recomputes on scan, on the debounced library-change pass, and immediately after a
delete.

The dashboard also shows a **storage ring** (Swift Charts `SectorMark` donut,
`StorageRingView`) visualising where reclaimable space lives against the rest of
the library, the **total library size** (`PhotoLibraryService.totalLibraryBytes`,
a `nonisolated` sum of every asset's on-disk size measured off-main once per scan
so it never blocks the UI), and a one-tap **Recommended cleanup** — the engine's
conservative pre-selected near-duplicates, opened pre-checked in the shared
`AssetCleanupScreen` (which gained an `initiallySelected` parameter). Recommended
cleanup still requires the user to confirm; nothing about the safety model
changes.
