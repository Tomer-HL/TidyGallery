# Calibration images

Drop a handful of representative photos here, then push. The `CalibrationTool`
macOS target analyses them and prints a tuning report into the CI
**Run calibration report** step. No special naming needed — any filenames and
any case of extension (`.JPG`, `.HEIC`, …) work.

## Good sample set

Aim for ~10–20 images covering the real cases:
- A couple of true bursts (near-identical, a few seconds apart).
- Within a burst, include a deliberately blurry one and a sharp one.
- If people are involved, include one with eyes closed vs. open, smiling vs not.
- A few clearly unrelated photos so "different-group" distances are represented.

## ⚠️ Privacy — this repo is PUBLIC

Anything committed here is publicly visible. Do **not** commit private photos.
Options:
- Use non-sensitive images you don't mind being public, **or**
- Temporarily set the repo to Private (Settings → Danger Zone → Change
  visibility). Private repos still get enough free macOS CI minutes for a
  handful of calibration runs.

You can delete these images (and this folder's contents) once the thresholds
are dialled in.
