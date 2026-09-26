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

For questions 4 and 5, `meterocr` also runs `VNDetectBarcodesRequest` (revision 4, all symbologies). Candidates for the meter number are the digit-bearing tokens of every recognized line: runs of digit groups merge, so `12 345 678` is one token, and a line of two to four groups is also offered whole. A candidate is right when it equals the labelled number after dropping separators and any letters before the first digit, so `NO. 12345678` and `ABC 123456` count, but a barcode line that merely contains the number does not. A text token is barcode-confirmed when it equals a part of a decoded payload. When it sits inside a longer payload part, it takes the payload's full string, which repairs reads that dropped a digit. The ranking scores each candidate as 8 × barcode-confirmed + 3 × after a `No.`/`Nr.`/`#:` label + 2 × alone on its line + 1 × 6–14 characters with 5 or more digits − 6 × on a specification line (voltages, ratings, `Kh`, `CL200`, `FORM`…) − 4 × rotated text − 6 × all zeros, with ties broken toward taller print.

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

### 4. Barcodes confirm the number when there is one

| Photos | Barcode found | Decoded | Decode contains the meter number |
|---|---|---|---|
| 80 | 25 | 25 | 20 of 24 with a labelled number |

Every barcode Vision found also decoded, and 20 of the 24 decodes on photos with a labelled number contain it, well above the one-third bar. Vision found a barcode on 9 of the 22 US-style meters, and 8 of those decode to the meter number. The four misses encode a different identifier: a Hydro-Québec barcode carrying a second utility number, and QR codes on two Taiwanese smart meters and a Japanese meter carrying the maker serial or a product record.

### 5. Finding the number: a tap-to-confirm screen does not yet clear the bar

| Rule | Held-out photos: precision | Held-out: recall | All 71 read photos: precision | All: recall |
|---|---|---|---|---|
| Tallest digit line (phase 1 guess) | 30% | 30% | 28% | 28% |
| A barcode confirms a text line | 6/8 = 75% | 18% | 17/20 = 85% | 24% |
| Line nearest a decoded barcode | 6/9 = 67% | 18% | 13/20 = 65% | 18% |
| After a `No.`/`Nr.`/`#:` label | 5/10 = 50% | 15% | 11/20 = 55% | 15% |
| Alone on its line, 6–14 characters, not a specification line | 23/33 = 70% | 70% | 45/70 = 64% | 63% |
| Barcode, else label word | 11/17 = 65% | 33% | 27/36 = 75% | 38% |
| Ranking, number is first | – | 21/33 = 64% | – | 48/71 = 68% |
| Ranking, number in the top three | – | 28/33 = 85% (69%–93%) | – | 64/71 = 90% (81%–95%) |
| Number is any candidate at all | – | 29/33 = 88% | – | 66/71 = 93% |

Held-out photos are the 33 even-numbered photos whose number Vision read; the rules were committed before they were scored. Verdict: both criteria fail. No rule reaches 95% precision, so the app cannot fill in the number unasked. The top three hold the number on 85% of held-out photos, short of 95%, so a tap-to-confirm screen alone would still send about one homeowner in seven back for a retake or a typed entry.

Ten photos went wrong: on seven the top three missed the number, and on three the barcode rule picked the wrong identifier. They split evenly between two causes:

- **Several real identifiers on one plate.** The rule picked another identifier that is printed on the meter: a maker serial next to a utility plate, a second barcode, or a `SERIAL#` line. On these photos the question is which identifier Base needs, and a homeowner tapping a list cannot answer that either. Base should say which identifier it uses for each utility, or accept any printed identifier.
- **Vision split the number or merged a neighbour into it.** A prefix or digits landed in a separate observation (a number printed like `S12 A345 678` read as `12A345` and `678`), or a neighbouring character joined it, so the exact number never appears as a candidate.

On the 19 read US-style meters, the barcode rule was right on all 8 of its picks (68%–100%). That is the one case where filling in the number without asking is supported, though on few photos. The ranking's top three held the number on 16 of the 19.

## For the app: checks to port

Every check runs on the full-resolution photo after applying its EXIF orientation. "Luma" is the 8-bit image L = 0.299 R + 0.587 G + 0.114 B. The number's box is Vision's normalized `boundingBox` of the chosen line (the union of the observations if the number spans several), converted to a top-left origin. `src/meter_eval/retake.py` implements the same definitions, and `tests/test_retake.py` holds hand-computed cases.

| Check | Input | Formula | Retake when |
|---|---|---|---|
| Number too small | number's box | box height × photo height in pixels | 12 px or less |
| Out of focus | whole photo, luma | resize so the long side is 1024 px (bilinear with antialiasing, as PIL); convolve with the 4-neighbour Laplacian [[0,1,0],[1,−4,1],[0,1,0]] over interior pixels; population variance | 6.63 or less |
| Glare | number's box padded by 0.25 × line height on every side, clipped to the photo | share of luma pixels ≥ 250 | 0.0729 or more |
| Cut off | number's box | smallest gap to the four photo edges ÷ line height | 0 or less |
| No number | ranking below | no candidate at all | always |

Finding the number: read with `VNRecognizeTextRequest` revision 3, `.accurate`, `en-US`, language correction off, `minimumTextHeight` 0, and run `VNDetectBarcodesRequest` revision 4 on the same image. On US meters, fill in a barcode-confirmed candidate without asking (8 of 8 here). Otherwise show the three best candidates by the score in the method section, with a "none of these" choice that asks the homeowner to type the number while at the meter. `src/meter_eval/locate.py` is the reference for the candidate tokens, features and score.

## Field test before trusting the thresholds

Commons photos are processed JPEGs from many cameras, not frames from the app's camera pipeline. Sharpening, noise reduction and tone mapping change the sharpness and saturation values, so the focus and glare thresholds may move in the app; the size and framing thresholds depend only on geometry and should hold. Take these close-ups of one real meter with the app's own capture path (or the iPhone camera if the app is not ready), then run `uv run python -m meter_eval.fieldtest PHOTO_DIR --number "<number as printed>"`. It prints each photo's read result and check values, and counts retakes asked for photos that read and photos accepted that did not.

| Threshold | Photos to take | It holds if |
|---|---|---|
| Number too small | square to the meter from 15, 30, 50, 80 and 120 cm | photos read down to about 15 px of line height and fail at 12 px or less |
| Out of focus | three with focus locked on a distant background, one from 5 cm (inside the minimum focus distance), three sharp | blurred photos score 6.63 or less and fail to read; sharp photos score far above |
| Glare | the flashlight of a second phone held beside the camera at 0°, 20° and 45°, or direct sun, with the reflection on the number | photos with 7.3% or more saturated pixels on the number fail to read; the rest read |
| Cut off | the frame edge cutting a quarter digit, half a digit and one whole digit | every cut photo is flagged |
| Hand shake (no check yet) | three in shade while sweeping the phone sideways during capture | records how often shake alone breaks reading; if it does, gate capture on gyroscope motion instead of an image score |

## Checking the labels by hand

Running `make review` builds `~/house-scanning-data/meter-closeup/review.html` outside git, because it shows the plaintext meter numbers. Open the file in a browser. Each photo appears cropped to its number, beside the number the AI readers settled on. Press K to keep it, or F to type a correction and Enter to save it. Progress stays in the browser, so the page can be closed and reopened. "Download answers" saves a CSV. `uv run python -m meter_eval.review ingest <csv>` stores it for `python -m meter_eval.labels`, which then treats kept numbers as agreed and corrected ones as the label; rerun the tables after that.

## Rerun

Needs macOS with Xcode 26 (Swift 6) and uv. From this folder:

```sh
make images   # download the 83 photos to ~/house-scanning-data/meter (set METER_DATA to change)
make q1       # results/clean.md and results/clean_per_image.csv, about a minute
make sweep    # the degraded reads, two processes of up to 2 GB, about 15 minutes
make q2       # results/sweep.md and results/sweep_rows.csv
make q45      # results/locate.md and results/locate_per_image.csv, about a minute
make review   # the label review page, outside git
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
- The number-finding rules were written on half of the photos after the author had read every photo while labelling, so the held-out half limits but does not remove fitting to this set. Its 33 photos give wide intervals.
- Which identifier counts as "the meter number" was the AI readers' call. Utility-assigned plates were preferred over maker serials, which decides five of the number-finding misses.
