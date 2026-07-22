# Shipping TidyGallery to TestFlight

Everything CI can do is done. This is the part that needs a human with an Apple
Developer account, plus the copy to paste into the forms.

## Why TestFlight, specifically

The app's memory design — paged fetches, bounded concurrency, ~512px
thumbnails — exists for a 20,000-photo library and has only ever met a
212-photo one. Every projection in the README extrapolates from that.

Two ways to fix that. A synthetic harness that inserts thousands of generated
assets tests the paging honestly, but generated images are poor proxies for
Vision cost, so it validates memory and not timing. TestFlight gets both, from
real photos, without building anything — because the Diagnostics screen is
already the instrument. It emits plain text with no photo content and a Share
button.

So the ask of testers is small and specific: **scan, then send the report.**

## One-time setup

### 1. Apple Developer Program

$99/year. TestFlight needs it; sideloading (`build-ipa.yml`) does not, and stays
available if you'd rather not pay yet.

### 2. Register the bundle identifier

`com.tidygallery.app` — matches `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.
If you change it in one place, change it in the other.

Capabilities: **none**. No push, no iCloud, no App Groups, no background modes.
Photo access is a usage-description string, not a capability.

### 3. Create the app record in App Store Connect

- Platform: iOS
- Name: TidyGallery (must be globally unique; have a fallback ready)
- Primary language, bundle id, SKU (any internal string)

### 4. App Store Connect API key

Users and Access → Integrations → App Store Connect API → **+**

- Access: **App Manager**
- Download the `.p8` immediately. It is offered exactly once.

### 5. Repository secrets

Settings → Secrets and variables → Actions:

| Secret | Where it comes from |
|---|---|
| `ASC_KEY_ID` | The key's ID, e.g. `2X9ABC3DEF` |
| `ASC_ISSUER_ID` | Shown above the key list, a UUID |
| `ASC_PRIVATE_KEY` | Full contents of the `.p8`, including the `BEGIN`/`END` lines |
| `TEAM_ID` | Membership details, 10 characters |

Paste the `.p8` verbatim — newlines and all. The workflow checks all four up
front and fails with a clear message if any is missing, rather than dying inside
a signing error a hundred lines deep.

### 6. Run it

Actions → **TestFlight** → Run workflow. Build number comes from the run number,
so it's unique without any state to maintain. Processing takes 5–15 minutes.

## Export compliance

Already answered in `project.yml` as `ITSAppUsesNonExemptEncryption: NO`, so App
Store Connect won't ask per build.

That answer is accurate, not merely convenient: there is no `URLSession`,
`URLRequest`, or any other networking API anywhere in the app target, and no
cryptography beyond what iOS applies to files at rest — which is the exemption
the question describes.

## Privacy nutrition label

**Data Collected: None.** Select "No, we do not collect data from this app."

Verified against the code rather than intent, because this is a legal
declaration:

- No `URLSession` / `URLRequest` / `NWConnection` in the target.
- No third-party packages at all. The only `dependencies:` entry in
  `project.yml` is the test bundle depending on the app.
- No analytics, crash reporting, or attribution SDK. No `AdSupport`, no
  `AppTrackingTransparency`.
- Photos are read through `PHImageManager` and analysed by Vision on-device.
  Feature prints and scores persist to a local SwiftData store.
- Diagnostics reports are shared **only** when the user taps Share, and contain
  counts, timings and memory figures — no photo content, no identifiers.

One point of honesty if anyone asks: the app sets
`PHImageRequestOptions.isNetworkAccessAllowed = true` when loading thumbnails,
and optionally during analysis if the user enables "Analyse iCloud photos".
That is iOS downloading the user's own photo from their own iCloud account
through Apple's framework. Nothing is uploaded, and no data reaches any server
of ours — there isn't one.

### Support URL

Required. A GitHub Pages page or the repo README URL is enough for TestFlight.

## Beta App Review

Internal testers (up to 100, on your own team) need **no review** — fastest path
to real data.

External testers need a Beta App Review, usually a day or less. Expect them to
check the deletion flow, so the review notes matter:

> TidyGallery finds duplicate and low-quality photos entirely on-device using
> Apple's Vision framework. No account, no network service, no data collection.
> Deletion always routes through `PHAssetChangeRequest.deleteAssets`, which
> presents the system's own confirmation sheet; the app never deletes without
> both its own confirmation and the system prompt.
> To test: allow photo access, tap Scan my library, open any cleanup category.

## What to Test

Paste into App Store Connect → TestFlight → build:

> **The one thing I actually need: the Diagnostics report.**
>
> Scan your library, then open the menu → Diagnostics → Share report and send it
> to me. It's plain text — counts, timings and memory. No photo content.
>
> Especially useful if you have more than ~5,000 photos. The app is built for
> large libraries and has only ever been tested on a small one, so your numbers
> are the whole point of this build.
>
> Also worth flagging:
> - Anything suggested for deletion that you'd have wanted to keep.
> - Anything where the count on a button didn't match what you saw.
> - The app being killed mid-scan. Reopen it — Diagnostics will say so.
>
> Nothing is ever deleted without you confirming twice: once in the app, once in
> iOS's own sheet. Deleted photos go to Recently Deleted for 30 days.

## Reading what comes back

| Reading | Interpretation |
|---|---|
| Min headroom > ~300 MB | The paging design holds at that library size. |
| Min headroom 50–300 MB | Works, but tight. Lower `maxConcurrentAnalyses` or `pageSize`. |
| Min headroom < 50 MB | A jetsam kill is luck. Act on it. |
| "the previous scan started but never finished" | It already happened. This is the finding. |
| Peak footprint climbing page over page | A leak — precisely what the paging exists to prevent. |
| Size cache hit rate < 100% on a second scan | Something is invalidating `modificationDate` unexpectedly. |
| Projection absent | Fewer than 25 fresh photos; the run was too cached to extrapolate. Not an error. |

The projection is deliberately withheld on small samples — it produced a
97-minute estimate from four photos once, against 22 minutes from fifty-six. If
you want a timing number from a tester, ask them to scan a library the app
hasn't seen before.

## Before the first external build

- [ ] Screenshots (6.7" required) — the App Store won't take a submission without them
- [ ] Support URL live
- [ ] Privacy label submitted as "No data collected"
- [ ] Decide the two open product questions in the README's Phase 21 notes:
      the post-delete auto-ignore of kept photos, and whether Recommended
      cleanup should open fully pre-checked
