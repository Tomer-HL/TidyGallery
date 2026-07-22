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
    ├── FaceLandmarkEvaluator.swift   EAR + mouth-curvature geometry (pure)
    ├── MemoryProbe.swift             phys_footprint + jetsam headroom
    └── DeviceSummary.swift           Hardware/OS/build line for reports
```

Phase 18's instrumentation also adds `Models/ScanMetrics.swift`,
`Persistence/ScanMetricsStore.swift` and `Views/DiagnosticsScreen.swift`.
Phase 20 adds `Persistence/CachedAssetSize.swift` and
`Persistence/AssetSizeCacheStore.swift` — the on-disk size cache.

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

## Validating it at scale (the current step)

The engine is feature-complete; what it has never been is *measured*. Run this
before doing any more feature or polish work, because the result changes what's
worth building next.

1. Sideload the current build (see above) onto a phone with a real library.
2. Settings → **Detection settings** is not what you want here — use menu →
   **Diagnostics**.
3. Scan at **Past month** first. Note peak footprint and lowest headroom.
4. Scan again at **Entire library**. Leave Diagnostics open while it runs if you
   want to watch memory move; it updates live.
5. **Share report** and send yourself the text.

What the numbers mean:

| Reading | Interpretation |
|---|---|
| Lowest headroom > ~300 MB | Comfortable. The paging design is doing its job. |
| Lowest headroom 50–300 MB | Works, but tight on smaller devices. Lower `maxConcurrentAnalyses` or `pageSize`. |
| Lowest headroom < 50 MB | Too close to the edge; a jetsam kill is a matter of luck. |
| "A scan was terminated mid-run" | It already happened. This is the finding. |
| Analysis failures in the thousands | Systematic, not bad photos — read the reasons. |
| Peak footprint climbing page over page | A leak: something is being retained across pages, which is exactly what the paging is meant to prevent. |

The projected time for 20,000 photos is an order-of-magnitude estimate, not a
promise — it extrapolates the measured per-photo cost at the concurrency actually
achieved.

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
much space is reclaimable (`StorageSummary`), with a per-category byte breakdown.
It covers **duplicate extras, large videos, big files, screenshots, and screen
recordings**, de-duplicated so an asset in two categories isn't summed twice.
Two deliberate choices: duplicates count their *potential* saving (everything
except each group's best shot) to match the card's "up to X" framing — the much
smaller conservative pre-selected subset is what "Recommended cleanup" acts on —
and because that id set now runs to thousands of assets (every screenshot and
duplicate extra), the sizes are measured **off the main actor**
(`PhotoLibraryService.assetFileSizes`, `nonisolated`) from a cancellable
background task, so the UI never hitches while it recomputes. Below it the
categories are grouped into sections: **Reclaim space** (Duplicates, Large
videos, Big files, Screen recordings), **Clutter** (Screenshots, Possibly
blurry), and **By content** (Food, Pets, Documents, Nature, Selfies). The summary
recomputes on scan, on the debounced library-change pass, and immediately after a
delete.

Phase 20 (caching the last expensive thing): diagnostics from an iPhone 12 mini,
199 assets, **100% analysis cache hit** — not one image decoded, not one Vision
request run:

```
Wall clock:        1.3 s
Size measurement   1.7 s   (1x, 8.8 ms per asset)
Metadata pass      936 ms  (1x, 4.7 ms per asset)
Vision analysis    —       (every photo served from cache)
Peak footprint     23.3 MB against 2.03 GB headroom
```

A scan that did no image work at all still cost 2.7 seconds. Both expensive
phases are the same call — `PHAssetResource.assetResources(for:)`, the only way
to read a file's size — and **neither was cached**. `CachedAnalysis` stored
feature prints and scores because those were obviously expensive; file sizes were
not, because reading a number felt cheap. At 8.8 ms each, a 20,000-photo library
was paying roughly **three minutes of resource walking on every launch** to
recompute numbers that cannot have changed.

The fix is the one already proven for analysis. `CachedAssetSize` +
`AssetSizeCacheStore` persist sizes keyed on `PHAsset.modificationDate` — the
same staleness signal `CachedAnalysis` uses, and the right one: the date moves
when an edit adds an adjusted resource, which is exactly when the on-disk total
changes. It also moves on a favorite toggle, costing one needless re-measure;
that is the safe direction to be wrong in. Sizes are *not* purged when tuning
changes (a file's size doesn't depend on how we score it) but *are* purged when
the change observer reports deletions, so the cache can't grow unbounded.

`PhotoLibraryService` owns the read/write path, so every size lookup in the app
benefits without any call site knowing. It works in bounded batches of 500:
consult the cache, walk `PHAssetResource` for the difference only, write back.
Batching keeps the misses re-fetch and the SwiftData `IN` query off the whole
library at once, and commits progressively — a first scan killed midway keeps
what it already measured.

Three things this got wrong on the first pass, all found in review:

1. **A new cancellation point needs a new contract.** The batch loop returns
   early when cancelled, which the old measurement could never do. "Big files"
   filters on `size >= minBytes`, and a missing entry is indistinguishable from
   a small file — so a truncated map silently shrinks the category. Fixed with
   `SizeMeasurement.isComplete`; `computeBigFiles` now returns `nil` rather than
   publishing a confidently wrong shorter list, and the caller keeps the
   previous one. The cleanup grid had the same latching bug.
2. **The measurement was reporting itself wrong.** Dividing the whole pass's
   wall clock by the number of fresh measures bills 20,000 cache lookups to
   however few assets actually changed — so "cost per measure" would appear to
   explode precisely when the cache works best. Only the `PHAssetResource` walks
   are timed now (`sizeWalkSeconds`).
3. **The counters were never persisted.** Size measurement is fire-and-forget
   from the analysis pass, and `scan()` saves the report before it finishes, so
   the saved copy always read zero. `applyLibraryMeasurements` re-saves.

Diagnostics gained an **On-disk sizes** section (from cache / freshly measured /
cost per measure) so the next device run can confirm the hit rate rather than
assume it.

Phase 19 (acting on the measurements): the Phase 18 instrumentation was pointed
at a real 228-photo library on an iPhone 11 Pro Max, and it answered the wrong
question — which is the useful kind of answer.

**Memory was never the risk.** Peak footprint 59.8 MB against 1.99 GB of
headroom. Every OOM precaution in this README works, and none of it was the
binding constraint. **Time is**: 269 ms per fresh photo, projecting to roughly
**45 minutes for 20,000 photos** — optimistic, since sustained Vision work will
thermally throttle.

Three separate scaling problems, all traceable to one decision.
`PhotoLibraryService` was `@MainActor`, on the reasoning that Photos delivers its
change notifications there. What that actually bought:

- The "instant" metadata pass measured 4.5 ms **per asset on the main thread** —
  607 ms at 110 photos, 1,022 ms at 228, and about **90 seconds of frozen UI** at
  20,000. The pass whose entire selling point is appearing immediately.
- Analysis achieved only 2–3× parallelism from a 4-wide pool, because every
  worker queued on the main actor for `analysisImage`, which also ran a
  `PHAsset.fetchAssets` per photo. The ceiling was the actor, not the CPU.
- `assetPages()` built its `AsyncStream` with a closure that runs synchronously
  on the caller's executor, so it enumerated and snapshotted the *whole* library
  on the main actor before the consumer saw one page — defeating the paging it
  existed to provide.

So the service is now `Sendable` with no isolation at all. The Photos read APIs
are thread-safe; this file already depended on that for `libraryFileSizes`. Three
details are load-bearing and easy to undo by accident:

- The heavy enumerations are `async` **even though they never await**. A
  nonisolated *sync* function called from `@MainActor` still runs on the main
  actor, and so does the body of a `Task {}` or `async let` started there. Only a
  nonisolated *async* function is guaranteed to reach the cooperative pool
  (SE-0338). Dropping `async` would silently re-block the main thread with no
  diagnostic anywhere.
- `scope` is no longer mutable state on the service — shared mutable state is
  precisely what made it hard to move — so every date-filtered fetch takes it.
- The UI thumbnail methods stay `@MainActor`, alone in the file, because
  `UIImage` isn't `Sendable` and there was nothing to win: the decode happens on
  `PHImageManager`'s own queue regardless.

`libraryFileSizes` also **had no scope predicate** — it walked every asset in the
library even when the user asked for one month, at ~9.6 ms each (2.2 s for 228,
minutes at 20k). It was simultaneously the most expensive thing the app did and
the one place the app's only cost lever did nothing. Now scoped, which makes the
dashboard's total a measure of what was scanned — so the copy says "scanned"
rather than "in your library", because it would otherwise be a wrong number.

Tuning, now that the actor is out of the way: `analysisImageSize` (384, down from
512 — 44% fewer pixels, and both decode and Vision scale with pixel count) and
`maxConcurrentAnalyses` (6, up from a 4 that was never actually reached). Both
live in `AnalysisConfiguration`. **`analysisImageSize` is coupled to two things
that break quietly if it moves**: Laplacian sharpness is scale-dependent, so
`blurrySinglesSharpnessCeiling` is calibrated for a specific size, and face
landmarks need faces to span enough pixels — going much lower starts losing the
small distant faces in group shots, which is exactly where eyes-closed detection
earns its keep.

Still outstanding: aesthetics runs `CalculateImageAestheticsScoresRequest` as a
**second** full Vision pass, so the "one Vision pass per photo" claim in Phase 11
was never true. Folding it into the shared `VNImageRequestHandler` needs
`VNCalculateImageAestheticsScoresRequest`, whose availability hasn't been
verified against the SDK — and this project has already been bitten once by
guessing at a Vision symbol.

Phase 18 (measuring it, finally): every memory claim in this README — paged
fetches, snapshot value types, bounded concurrency, ~512px analysis images — was
an *assertion*. None had been measured on hardware against a real library. A
scan now instruments itself.

`ScanMetrics` (a pure, `Codable`, `Sendable` value type, so the aggregation and
report formatting are unit-testable without Photos, Vision or a device) records
per-phase wall clock, counts by outcome, and memory. `DiagnosticsScreen` (menu →
Diagnostics) shows it and shares it as plain text.

Three things about it are deliberate:

**Headroom, not footprint.** `MemoryProbe` reports both `phys_footprint` and
`os_proc_available_memory()`. Peak footprint alone predicts nothing — the jetsam
limit differs by device and by what else is resident, so "peaked at 380 MB" is
comfortable on one phone and fatal on another. Headroom is how many bytes the
process may still allocate before it is killed, which is the number the question
"does this survive 20,000 photos on the smallest supported device?" actually
turns on.

**Detecting the kill that leaves no trace.** When iOS jetsams an app, the app
runs no code: no `catch`, no `deinit`, no crash log of ours. It is invisible from
the inside. So a scan writes a marker before it starts and clears it at the end
(`ScanMetricsStore`, in `UserDefaults` — it has to survive a kill mid-SwiftData-
write and be readable before the model container exists). A later launch finding
the marker still set means the previous scan was terminated mid-flight, which for
a photo-analysis pass is an OOM until proven otherwise. That one boolean is the
most valuable thing the instrumentation produces, and Diagnostics leads with it.

**A real bug found by writing this.** Analysis ran `try await analyzer.analyze(…)`
directly inside the task group, so a Vision throw propagated out and tore down
the group — failing the *entire scan*. Across 20,000 photos, one image Vision
dislikes took everything with it. Now the failure is caught per photo, counted by
reason, and the scan continues; the reasons are listed in Diagnostics, where a
handful reads as normal and thousands of the same message reads as systematic.

Timings are carried back on the task result rather than written to a shared
counter, so nothing in the hot path needs an actor hop: the accumulation happens
on the main actor, where it's trivially race-free. Cost is a few integer
increments per photo and one `task_info` call per page.

Phase 17 (onboarding + polish): a one-time welcome screen (`OnboardingView`,
gated on a `UserDefaults` flag) runs before the first scan. For an app that
deletes photos, the lead point is the safety promise — "nothing is deleted
without you", "everything stays on your phone", "deleted photos are recoverable
for 30 days" — established up front rather than buried. The home also now shows a
friendly "All tidy" card when a scan finds nothing actionable, nudging the user
to widen the scan scope instead of just presenting a wall of empty categories.

Phase 16 (self-diagnosing categories): after several rounds of *guessing* what
Vision labelled a photo and rebuilding to check, the classifier's top labels are
now kept (`ClassificationLabel`, persisted with the analysis, schema v6) and
shown in a "Detected on-device" section of the "Why this photo?" sheet —
"Child 42%, Cat 17%, Sofa 11%". A miscategorisation is now self-explanatory:
long-press the photo, read the labels, and the fix is obvious (adjust a keyword,
raise the confidence floor) without a build-and-sideload round-trip. The labels
are computed once during analysis anyway — the same ranked list that drives the
category tags — so this adds a cache field, not analysis cost.

Phase 15 (classification accuracy): real-device testing surfaced three
misclassifications, each with a different cause.

**Selfies was conceptually wrong.** The rule was "a face fills much of the
frame" — but that describes a close-up *portrait*, so photos a parent takes of
their child matched perfectly. What actually defines a selfie is the
front-facing camera, which iOS already tracks: Selfies now comes from the system
`smartAlbumSelfPortraits` album, like Screenshots does. That's more correct *and*
free — it needs no Vision pass, so Selfies joins the instant metadata categories.

**The confidence floor had been over-corrected.** When Food/Documents came up
empty, the floor dropped 0.5 → 0.05 with the top 10 labels. In a ~1300-class
taxonomy that tail is noise, and one stray "cat" or "poster" was enough to file
a child under Pets. Now 0.15 with the top 5.

**Some Documents keywords were far too generic** — "print", "card", "label",
"sign", "poster", "letter", "note". An ordinary photo of a room matches one of
those trivially. Pruned to words that only appear in actual documents.

Plus a signal that was computed and ignored: **a document contains no human
face**, so a detected face now vetoes the Documents tag outright — faces are far
more reliable than a weak "page" label.

Phase 14 (iCloud-aware analysis): with "Optimize iPhone Storage" many photos
exist locally only as a small degraded placeholder. This was a correctness bug,
not just a gap — analysing that placeholder is actively wrong: Laplacian
sharpness measured on a downscaled thumbnail is artificially low (a sharp photo
gets reported blurry) and its feature print doesn't match the full-resolution
one, so duplicate matching breaks.

`analysisImage` now returns a typed `AnalysisImage` — `.image`, `.inCloud`, or
`.unavailable` — and **never accepts a degraded frame**. When the full-quality
image is in iCloud and downloading isn't permitted, the photo is left
un-analysed and counted, instead of being silently dropped or badly scored. (The
degraded-plus-in-cloud case also resolves the continuation immediately rather
than waiting for a callback that will never arrive.)

The count surfaces as a home banner explaining that those photos are missing
from Duplicates and the content categories, with a one-tap "Download and analyse
them" that flips the new `analyseICloudPhotos` setting and rescans. That setting
needs a rescan but **not** a cache purge: previously-skipped photos have no cache
entry, and everything already analysed locally is still valid — so
`requiresCachePurge` is now distinct from `requiresReanalysis`.

Phase 13 (scan scope + progressive results): the app no longer makes you wait
for the whole library before showing anything.

**Scope.** `ScanScope` (past month / 3 months / year / entire library, persisted)
becomes a `creationDate` predicate applied to *every* fetch, so narrowing the
window does proportionally less work rather than the same work reordered. This is
the only lever that genuinely reduces analysis cost, because cost scales with
photo count. Note it can't be done per content category: "only scan food" is
circular, since classification is what identifies food in the first place.

**Progressive results.** A scan now runs in two passes. Screenshots, videos,
screen recordings and big files come from metadata alone — no Vision, no image
loads — so they're published within a second or two and the home opens
immediately. Vision analysis then runs behind it, newest-first, re-clustering
early and then periodically so Duplicates and the content categories fill in
while the user is already cleaning. A banner explains what's still arriving; the
rest of the screen is live throughout.

Phase 12 (explainability): long-press any photo — in a cleanup grid or a
duplicate stack — for "Why this photo?". `ScoreBreakdownView` shows the metric
bars the engine actually scored it on (sharpness, aesthetics, face quality) plus
plain-language observations from `ScoreExplanation`: "Someone's eyes look
closed", "Softer than the best shot", "Very close in quality to the best shot".
Inside a stack it compares against that group's best shot, so a recommendation
reads as reasoning rather than an edict.

The wording logic is pure and tested — it must never contradict the numbers, so
`ScoreExplanationTests` pins things like never inventing face observations for a
photo with no faces, and describing a near-tie as close rather than "clearly
worse". **Cost at scan time: none.** It's arithmetic over a `ShotScore` that was
already computed and cached, built for a single photo only when the sheet opens;
grids never construct it.

Phase 11 (scan performance): four fixes, in rough order of impact.

1. **Batched cache writes.** `store` issued a fetch *and* a `save()` per photo,
   so a 20k library meant 20k queries and 20k disk writes. `storeBatch` collapses
   each page to one query and one write — by far the biggest win.
2. **One Vision pass per photo.** *(Correction: not quite — see Phase 19.
   Aesthetics still runs a second pass.)* Feature print, faces and classification
   share a single `VNImageRequestHandler.perform`. Classification previously ran
   in its own handler, and every handler re-processes the image, so this roughly
   halves the Vision work. Classification is optional, so a failed batch retries
   with just the required pair.
3. **One video enumeration.** `fetchVideosAndScreenRecordings` returns both in a
   single pass; they were previously fetched separately, walking every video
   twice and repeating the `PHAssetResource` lookup each time.
4. **Cheap re-filtering.** Refreshing is split into a full pass (re-enumerate,
   then derive) and a derived-only pass (re-filter lists already in memory).
   Ignoring a photo used to re-enumerate the entire library just to hide one
   asset; now it only re-filters.

Phase 10 (hardening): the scan coordinator is bound to Photos, Vision and
SwiftData, so testing it directly would mean heavy mocking. Instead the
*derivation* logic — the part that actually decides what the user sees — was
extracted into pure value types that need no mocking at all:

- `BlurrySinglesSelector` — the relative percentile-plus-ceiling rule, with
  tests proving a uniformly-soft library is still bounded, a sharp library flags
  nothing, favorites are excluded, and the hard cap holds.
- `StorageSummaryBuilder` — reclaimable-space maths. Its tests pin the subtle
  part: categories OVERLAP (a big screenshot is both), so the headline total is
  computed over the de-duplicated union while line items report their own ids.
  Summing the lines would overstate what deleting actually frees.
- `PhotoStack.removing(_:)` — pruning after deletion, with tests that a stack
  dissolves below two photos and the best shot is always a surviving asset.

`TuningSettings` is covered too, including tolerant decoding (a settings blob
saved before a knob existed must not wipe the user's other choices) and the
re-scan classification. This left the coordinator thinner as a side effect.

Phase 9 (on-device tuning): a Settings screen (gear on the home) exposes the
detection knobs as sliders — duplicate sensitivity, "possibly blurry" share,
big-file floor, content-detection confidence and selfie sensitivity — so they can
be tuned on the phone instead of editing a constant, running CI and re-sideloading.

Two details matter. First, only the user-facing subset is persisted
(`TuningSettings` in `UserDefaults`, decoded tolerantly with `decodeIfPresent`)
rather than all of `AnalysisConfiguration`, so adding internal tunables later
can't silently reset the user's choices. Second, the screen distinguishes knobs
applied while *deriving* categories — which re-apply instantly by re-clustering
the working set already in memory — from the two applied during *analysis*
(scene confidence, selfie face size), which are baked into cached results and so
discard the cache and re-scan. The screen says which is which before you apply.

Phase 8 (organise): every cleanup grid gains a toolbar menu with **sort**
(newest / oldest / largest / smallest — size orders fall back to date until the
measurement lands, so the grid never looks shuffled) and an **age filter** (past
year / 1–3 years / older than 3 years). There is deliberately no free-text
search: photos carry no text to match, so the useful equivalent when cleaning up
is filtering by age. Selections can also be **exported to a Photos album**
(`PhotoLibraryService.createAlbum`) — this only references the existing assets in
a new collection, copying and removing nothing. Like `deleteAssets`, it's
`nonisolated`, since awaiting `PHPhotoLibrary.performChanges` from the main actor
is what caused the original delete crash.

Phase 7 (ignore list): photos the user decides to keep can be marked "don't
suggest again" from any cleanup screen ("Keep N"), and they're then filtered out
of *every* suggestion — all categories, exact-duplicate extras, stack
pre-selections, recommendations, and the reclaimable-space total. An "Ignored"
card on the home opens `IgnoredAssetsScreen` to review and undo those decisions;
that screen deliberately has no delete action.

Crucially, the list lives in its **own** SwiftData entity (`IgnoredAsset` +
`IgnoreListStore`), not in `CachedAnalysis`. The analysis cache is disposable and
is invalidated wholesale on every `schemaVersion` bump (four so far) — user
decisions must never be lost that way, so they carry no version coupling.

Phase 6 (exact duplicates): `ExactDuplicateFinder` catches the case visual
clustering structurally cannot — the *same* image present twice, however far
apart in time. Rather than hashing gigabytes of original data, it exploits the
fact that byte-identical copies must agree on cheap metadata: bucket by
`(pixelWidth, pixelHeight, fileSize)`, then confirm inside each bucket with the
feature prints already computed and cached (identical images give an identical
embedding, so distance is ~0). The per-asset sizes come from the same single
off-main pass that produces the dashboard total, so this costs no extra I/O.

Because an exact match involves no judgement call, these are the one thing the
app pre-checks: the "Exact duplicates" screen opens with every redundant copy
already selected. The safety rules still hold — **one copy of each group is
always kept**, and a **favorite is never offered for deletion** (a favorite is
preferred as the copy kept). They also feed "Recommended cleanup" and get their
own ring segment. `ExactDuplicateFinderTests` pins all of these invariants.

The dashboard also shows a **storage ring** (Swift Charts `SectorMark` donut,
`StorageRingView`) visualising where reclaimable space lives against the rest of
the library, the **total library size** (`PhotoLibraryService.totalLibraryBytes`,
a `nonisolated` sum of every asset's on-disk size measured off-main once per scan
so it never blocks the UI), and a one-tap **Recommended cleanup** — the engine's
conservative pre-selected near-duplicates, opened pre-checked in the shared
`AssetCleanupScreen` (which gained an `initiallySelected` parameter). Recommended
cleanup still requires the user to confirm; nothing about the safety model
changes.
