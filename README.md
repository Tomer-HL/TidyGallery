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
| Stacks | Time-clustered bursts only, ~10s window |
| Pre-selection | Conservative — only clearly-inferior near-duplicates |

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
blur half-saturation) are starting guesses. The `CalibrationReport` test tunes
them against real photos, and runs in the same free CI:

1. Add ~10–20 sample photos to `Tests/CalibrationImages/`, named with a group
   prefix (`beach_1.heic`, `beach_2.heic`, `dog_1.jpg`, `sunset.jpg`). See that
   folder's README for what makes a good set — and the **privacy note**, since a
   public repo makes committed images public.
2. Push. Open the CI run → **Run tests** step → search the log for
   `CALIBRATION REPORT`.
3. The report prints per-image scores, every pairwise feature-print distance
   (tagged same-group vs different-group), the stacks formed at current
   thresholds, and a suggested `featurePrintSimilarityThreshold` at the midpoint
   of the gap between same- and different-group distances.
4. Edit the constants in `Models/AnalysisConfiguration.swift`, push, repeat.

The harness never fails the build; with no images it just prints a notice.

## Not yet built (Phase 2)

SwiftUI stacks gallery, star badge on the best shot, toggle/override selection, and the confirmation flow that calls the already-present `PhotoLibraryService.deleteAssets(withIdentifiers:)`.
