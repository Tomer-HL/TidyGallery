# First run on your main iPhone (20,000+ photos)

The app has only ever met a 212-photo library. This run is the first time the
paging design meets the size it was built for, so the goal is **data, not
cleanup**. Don't delete anything on the first pass.

Nothing here can modify a photo. The whole app contains exactly two operations
that touch your library: deleting assets you confirm twice, and creating an
album that only *references* existing photos. There is no code that edits,
re-encodes, or uploads anything.

---

## Before you start

- [ ] Phone **plugged in**. This is 20+ minutes of sustained Vision work; it
      will get warm and it will drink battery.
- [ ] Take the case off if it's a thick one. Thermal throttling will slow the
      scan and skew the timings.
- [ ] Photos are backed up (iCloud Photos counts). You won't be deleting
      anything today, but do this before the day you do.
- [ ] Free up a couple of GB if you're near full — the analysis cache writes a
      feature print per photo (~3 KB each, so roughly 60 MB at 20k).

---

## 1. Get the build

GitHub → **Actions** → **Build IPA (unsigned)** → open the newest green run →
**Artifacts** → download `TidyGallery-ipa` → unzip → `TidyGallery-unsigned.ipa`.

Check the run is on commit `a9790c2` or later. Earlier builds have no app icon
and no crash-survivable diagnostics, which is most of what this run is for.

## 2. Install

**Sideloadly** (sideloadly.io) is the simplest: plug the phone in, drag the
`.ipa` on, enter your Apple ID, **Start**.

Then on the phone: Settings → General → **VPN & Device Management** → your
Apple ID → **Trust**.

Two limits of free sideloading, worth knowing before you plan around them: the
app **expires after 7 days**, and a free Apple ID allows **3 sideloaded apps**
at once.

## 3. Enable Developer Mode

Required since iOS 16 for anything development-signed, which includes every
sideloaded app. Without it TidyGallery installs perfectly and then simply
refuses to launch — which reads like a broken build rather than a missing
setting.

Settings → **Privacy & Security** → **Developer Mode** → toggle on → **Restart**
when prompted → unlock after the restart → **Turn On** at the confirmation.

**The menu item only appears after a development-signed app is installed**, so
do this *after* step 2, not before. If you can't find Developer Mode in
Privacy & Security, the install hasn't landed yet.

Two notes. This is a genuine, if small, reduction in device security — it exists
precisely so sideloading can't happen silently — and it stays on until you turn
it off. And it's a sideloading-only concern: **TestFlight builds don't need it**,
so this step disappears the day the app ships that way.

## 4. First launch

1. Open TidyGallery. It'll show a one-time welcome screen.
2. **Allow access to all photos** when iOS asks.
   - If you'd rather be cautious, "Select Photos" also works — the app handles
     limited access properly. But it won't answer the memory question, which is
     the point of this run.
3. Don't tap **Scan my library** yet.

## 5. Two things before you scan

**Confirm "Analyse iCloud photos" is off.** Gear → Detection settings. It's off
by default, so this is a check rather than a change — but if you use Optimize
Storage, turning it on makes the app download full-size originals for everything
not stored locally. That's a lot of network and disk, and it turns the timings
into a measurement of your Wi-Fi.

Related: if the home screen offers to analyse photos it skipped because they
live in iCloud, **decline it for this run.** Accepting flips that same setting
mid-scan and the numbers stop being comparable. You can always turn it on later
once you have a clean baseline.

**Set the scope to Past month** from the menu, for the first pass.

---

## 6. The run

### Stage A — smoke test (a minute or two)

Scope **Past month** → **Scan my library**. Let it finish.

Open the menu → **Diagnostics**. You're checking it works at all, and getting a
baseline. Note **Lowest headroom**.

### Stage B — the real one

Menu → **Rescan** → **Entire library**.

Leave **Diagnostics open while it runs** — it updates live. Watch **Lowest
headroom**, which matters more than peak footprint, because the limit differs by
device.

Expect roughly 20–40 minutes cold. The first scan analyses every photo; every
scan after that is mostly cache hits and takes seconds.

**Don't tap any delete button.** Scanning is entirely read-only.

If it gets uncomfortably hot or you need the phone, tap **Stop scanning** in the
banner on the home screen. That's recorded as a deliberate stop, not a crash,
and everything analysed so far is kept — the next scan resumes cheaply.

### Stage C — send it

Diagnostics → **Share report** → send it to yourself. It's plain text: counts,
timings, memory. No photo content.

---

## If the app disappears mid-scan

That's the interesting outcome, not a disaster — it means iOS killed it for
memory, which is exactly the thing that has never been tested.

**Just reopen the app.** Diagnostics will show "A scan was terminated mid-run"
along with how far the dead run got and how low headroom went, and a separate
**Share the interrupted run's report** button. Send that one.

Don't tap Scan first — reopening is enough to reach Diagnostics.

---

## What the numbers mean

| Reading | Interpretation |
|---|---|
| Lowest headroom > 300 MB | Comfortable. The paging design holds at your size. |
| Lowest headroom 50–300 MB | Works, but tight. Worth lowering concurrency. |
| Lowest headroom < 50 MB | Too close to the edge; surviving was luck. |
| Peak climbing page over page | A leak — the thing paging exists to prevent. |
| Peak 100–150 MB | **Expected.** One feature print per photo is ~60 MB at 20k by design. |
| "Projected for 20,000" absent | Fewer than 25 photos were analysed fresh. Not an error. |

---

## Don't touch these yet

**Recommended cleanup** and **Exact duplicates** open with *everything already
selected* and a red "Delete N · frees X GB" bar. On a 20k library that could be
hundreds of photos, two taps from launch. They're safe — two confirmations, and
Recently Deleted holds things for 30 days — but that's not where to start.

When you do want to try deleting, do it like this:

1. Open a normal category (Screenshots is a good one).
2. Select **two** photos you genuinely don't want.
3. Delete, confirm both prompts.
4. Open Photos → Albums → Recently Deleted. Confirm they're there and **Recover**
   one.

That's you verifying the deletion path rather than taking my word for it. Note
deletions sync to iCloud and all your devices — so does Recently Deleted, so
recovery works from anywhere.
