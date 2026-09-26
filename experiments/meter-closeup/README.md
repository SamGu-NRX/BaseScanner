# Meter close-up readability

The app photographs the electric meter so Base can read its meter number and class label (CL200, CL320). A homeowner must not be asked for photos again, so the phone has to decide before they leave whether a close-up is readable. This experiment measures that on real meter photos.

## Questions and pass criteria, set before the run

1. How often does Apple's on-device text recognition read the full meter number and the class label correctly? If it gets the number right on at least 90% of usable close-ups, the phone can gate capture on its own read. Below 70%, the phone should gate on photo quality and a server should do the reading.
2. Which cheap photo checks predict a failed read, and at what thresholds? A check is useful if, above its threshold, at least 95% of the photos that read correctly undegraded still read after controlled degradation.
3. Does a second pass (crop the detected label and read again) raise the read rate?

Questions 4 and 5 were added after the first run found that the phone reads the number but cannot tell which recognized line it is. Their criteria were committed before those measurements ran.

4. Does Vision's barcode detection find, decode and confirm the meter number? Measured on every usable photo: photos with a barcode found, with one decoded, and with a decode that contains the labelled number. A barcode is worth reading first if a decode contains the number on at least a third of the photos where a barcode is found.
5. Which rule picks the meter number out of the recognized lines? Each rule and the best combination are reported with precision (the pick is the number, among photos where the rule makes a pick) and recall (over photos whose number Vision read). The app can fill in the number without asking if the combination's precision is at least 95%. A tap-to-confirm screen showing the top three candidates avoids a retake if the number is among them on at least 95% of photos whose number Vision read. To limit fitting rules to the photos they are scored on, rules were written using only the odd-numbered photos (m01, m03, …) and committed before the even-numbered ones were scored; both halves are reported.

## Data and labels

83 photos from Wikimedia Commons (the `Electricity meters (kWh)` category and meter-brand searches), all under CC0, public domain, CC BY or CC BY-SA. `manifest.csv` records each photo's URL, license and author. The photos are not committed; `make images` downloads them. Three are excluded: two show several meters at once, and one label shows a customer's name and address. Of the 80 usable photos, 22 carry a US-style class label (CL200, 200 CL, CL20) and 57 an IEC current rating such as `10(60)A`. Most meters are Taiwanese, European or Canadian; US residential meters are a minority.

**The labels were made by AI readers, not people, so every number below is only as good as those labels.** Reader 1 (Claude Opus, the author of this experiment) read every photo, zooming into the original. Reader 2 (a separate Claude Sonnet agent) read every photo without seeing reader 1's labels. A meter number counts as agreed when both readers transcribed the same characters and neither doubted any; 73 of the 78 photos showing a number are agreed, and the accuracy figures use those 73. Where reader 2 doubted only which printed number is the meter's ID, and transcribed reader 1's number identically, the number counts as agreed (`labels.py` lists these cases). `manifest.csv` stores each meter number as a SHA-256 digest, because `CONTRIBUTING.md` forbids committing meter numbers; the digest is enough to score a read.

## Method

`meterocr/` is a Swift command-line tool that calls Vision's `VNRecognizeTextRequest` (revision 3, `en-US`, `minimumTextHeight` 0) on macOS, the same API the iPhone app would use. The primary configuration is `accurate` without language correction. A number counts as read when the whole labelled number appears exactly in one recognized line, or in lines sharing a row. This is an upper bound on what the app gets: the app must still pick which recognized string is the meter number.

For question 2, the 71 photos whose agreed number read correctly undegraded were degraded with five controlled transforms. These are synthetic changes applied to the real photos, and every level is scaled to the height of the number's line so it means the same thing at any resolution: Gaussian blur (focus), horizontal motion blur (hand shake), downscaling (label too small), a white glare patch over the number, and cropping the frame edge into the number. Each check was measured on the number's box (known from the undegraded read), on the tallest recognized line with 4 or more digits (what a phone can find without knowing the answer), or on the whole photo. For each photo and transform, the break is the first level from which it never reads again. A check's retake threshold is the value at or below which 95% of photos have broken. Every check meets the pre-set criterion by construction of its threshold, so the deciding test is the next one: how many of the 75 real, undegraded photos that read correctly each threshold would wrongly send back for a retake.

For question 3, every failed degraded read was retried on a crop around the tallest detected digit line, and on that crop upscaled 2x.

## Results

### 1. On-device reading works on these photos

| What was read | Photos | `accurate` | `accurate` + language correction | `fast` |
|---|---|---|---|---|
| Meter number, exact | both readers agree (73) | 71/73 = 97% (91%–99%) | 71/73 = 97% (91%–99%) | 55/73 = 75% (64%–84%) |
| Meter number, exact | all labelled (78) | 75/78 = 96% (89%–99%) | 74/78 = 95% (88%–98%) | 57/78 = 73% (62%–82%) |
| US class label | all labelled (22) | 20/22 = 91% (72%–97%) | 20/22 = 91% (72%–97%) | 14/22 = 64% (43%–80%) |
| Current rating, e.g. `10(60)A` | all labelled (57) | 57/57 = 100% (94%–100%) | 57/57 = 100% (94%–100%) | 39/57 = 68% (56%–79%) |

Ranges are 95% Wilson intervals. Verdict: the `accurate` level reads the full number on 97% of these close-ups, above the 90% bar, so the phone can gate capture on its own read. The `fast` level misses a quarter of numbers and should not be used for this; language correction adds nothing. The two agreed numbers it missed are a thin-print number split by dots, which Vision read only in part, and a utility plate on a dark background that Vision never detected. The two class labels it missed are an oblique shot with `CL` and `200` on separate plates, and a `CL` cut off by the frame edge.

The unsolved part is finding the number. On only 21 of 75 photos was the tallest recognized line with 4 or more digits the meter number; nameplates carry registers, serials, model codes and seal numbers. Four other text-only rules found it on at most 29 of 75.

### 2. Retake checks

| Problem | Check the phone computes | Retake when | Evidence |
|---|---|---|---|
| Label too small | height of the number's line | 12 px or less | 96% of photos read at 15 px, 77% at 12 px, 30% at 8 px; rejects 0 of 75 good photos |
| Out of focus | Laplacian variance of the whole photo scaled to 1024 px | 6.6 or less | AUC 0.96; rejects 0 of 75 good photos. Reading holds to a blur σ of 0.04 × line height (94%) and fails at 0.13 (4%) |
| Glare | share of pixels at 250 or above inside the label box | 7.3% or more | AUC 0.95; rejects 2 of 75 good photos |
| Label cut off | gap between the label box and the frame edge | no gap | a number ending exactly at the edge read 100%, but 13–17% once the edge cuts in by half a line height or more; a box that reaches the edge cannot show whether digits continue past it |
| Hand shake | none found | – | every sharpness score either misses streaks (AUC 0.69–0.85) or rejects 21–37 of 75 good photos |

Verdict: size, focus, glare and framing each have a check that meets the criterion and rejects almost no good photos. Motion blur does not: reading survives streaks up to 0.2 × line height (93%) but no image score tells those apart from good photos. Two checks tempting for glare fail on real photos: the label's contrast rejects 31 of 75 good photos (faded print reads fine), and the whole-photo saturated share rejects 47. The size, glare and framing checks need the label's location, which, as question 1 found, the phone cannot yet find reliably; the whole-photo focus check needs none. Even above every break, 0.7–2.6% of degraded reads failed anyway, which no photo check can prevent.

`results/sweep.md` has the full read-rate curves, every check's 95% and 80% thresholds, and the real-photo rejection counts.

### 3. A second pass rarely helps

Re-reading a crop around the detected digit line recovered 2–3% of failed reads for blur, motion, glare and framing. For labels made too small it recovered 6% as cut and 12% when the crop was upscaled 2x. Verdict: a retake beats a second pass; upscaling a small label is the only case worth adding. Combining two frames was not tested.

## Rerun

Needs macOS with Xcode 26 (Swift 6) and uv. From this folder:

```sh
make images   # download the 83 photos to ~/house-scanning-data/meter (set METER_DATA to change)
make q1       # results/clean.md and results/clean_per_image.csv, about a minute
make sweep    # the degraded reads, two processes of up to 2 GB, about 15 minutes
make q2       # results/sweep.md and results/sweep_rows.csv
make check    # lint and unit tests
```

`manifest.csv` is the committed output of `python -m meter_eval.labels`, which merges the two readers' plaintext labels; those stay in the data directory.

## Limits

- The labels come from AI readers (see above).
- Commons photos are mostly deliberate, well-lit close-ups; homeowners' photos will be worse, so 97% is likely optimistic. US residential meters are a minority of the set, and class labels were read on only 22 photos.
- Degradations are synthetic transforms of real photos: one glare model, horizontal motion only, and no noise, low light, compression or perspective. Class labels were not swept; the thresholds are for meter numbers.
- The class-label matching rule was loosened after the first run, to ignore separators and read `×` as `x`; every first-run miss was one of those. The meter-number rule was not changed.
- Sharpness values are in grey levels squared on 0–255 images and depend on the camera's processing. Recheck the thresholds on iPhone captures before shipping them.
- macOS Vision stands in for iOS Vision: same API and revision, not verified on a phone.
