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

**The labels were made by AI readers, not people, so every number below is only as good as those labels.** Reader 1 (Claude Opus, the author of this experiment) read every photo, zooming into the original. Reader 2 (a separate Claude Sonnet agent) read every photo without seeing reader 1's labels. The label is always reader 1's number, so reader 1 chose which printed identifier counts as the meter number: utility plates over maker serials. `labels.py` records two agreement rules:

- **Loose**, which the headline results use (73 of the 78 photos showing a number): reader 1's number equals any number reader 2 listed, its main number or one of its other numbers, or one contains the other with at least 6 characters in the shorter; and neither reader doubted a character. Reader 2 doubting only which printed number is the ID does not count as doubt (`labels.py` lists those photos).
- **Strict** (62 photos): both readers' main numbers are identical and both were sure.

`manifest.csv` stores each meter number as an HMAC-SHA256 digest, because `CONTRIBUTING.md` forbids committing meter numbers. An unkeyed hash of a short number can be reversed by trying every number of that length; without the key, which lives in `~/house-scanning-data/meter-closeup/hmac.key` and never in git, the digests reveal nothing. Scoring a read needs the key: get it from the team, or create a new one with `uv run python -m meter_eval.labels --new-key` and rebuild the manifest from the plaintext labels. `make leakcheck`, which also runs in CI with the key from a repository secret, fails if any identifier either reader transcribed appears in a tracked file.

## Method

`meterocr/` is a Swift command-line tool that calls Vision's `VNRecognizeTextRequest` (revision 3, `en-US`, `minimumTextHeight` 0) on macOS, the same API the iPhone app would use, and optionally `VNDetectBarcodesRequest` (revision 4, all symbologies). The primary configuration is `accurate` without language correction. A number counts as read when the whole labelled number appears exactly in one recognized line, or in lines sharing a row. This is an upper bound on what the app gets: the app must still pick which recognized string is the meter number.

For question 2, the 71 photos whose agreed number read correctly undegraded were degraded with five controlled transforms. These are synthetic changes applied to the real photos, and every level is scaled to the height of the number's line so it means the same thing at any resolution: Gaussian blur (focus), horizontal motion blur (hand shake), downscaling (label too small), a white glare patch over the number, and cropping the frame edge into the number. Each check was measured three ways. On the whole photo, which needs no locator. On the top candidate of the number-finding ranking below, which is what the phone can compute. And on the true number's box from the undegraded read, which the phone does not have, so those rows only show what a perfect locator would allow; for the framing transform that box is clipped to the frame, so its gap is 0 by construction. For each photo and transform, the break is the first level from which it never reads again. A check's retake threshold is the value at or below which 95% of photos have broken. Every check meets the pre-set criterion by construction of its threshold, so the deciding tests are the AUC over all degraded reads and how many of the 75 real, undegraded photos that read correctly each threshold would wrongly send back.

For question 3, every failed degraded read was retried on a crop around the top candidate, and on that crop upscaled 2x.

For questions 4 and 5, candidates for the meter number are the digit-bearing tokens of every recognized line: runs of digit groups merge, so `12 345 678` is one token, and a line of two to four groups is also offered whole. A candidate is right when it equals the labelled number after dropping separators and any letters before the first digit, so `NO. 12345678` and `ABC 123456` count, but a barcode line that merely contains the number does not. A text token is barcode-confirmed when it equals a part of a decoded payload. When it sits inside a longer payload part, it takes the payload's full string, which repairs reads that dropped a digit. The ranking scores each candidate as 8 × barcode-confirmed + 3 × after a `No.`/`Nr.`/`#:` label + 2 × alone on its line + 1 × 6–14 characters with 5 or more digits − 6 × on a specification line (voltages, ratings, `Kh`, `CL200`, `FORM`…) − 4 × rotated text − 6 × all zeros, with ties broken toward taller print.

## Results

### 1. On-device reading works on these photos

| What was read | Photos | `accurate` | `accurate` + language correction | `fast` |
|---|---|---|---|---|
| Meter number, exact | loose agreement (73) | 71/73 = 97% (91%–99%) | 71/73 = 97% (91%–99%) | 55/73 = 75% (64%–84%) |
| Meter number, exact | strict agreement (62) | 60/62 = 97% (89%–99%) | 60/62 = 97% (89%–99%) | 47/62 = 76% (64%–85%) |
| Meter number, exact | all labelled (78) | 75/78 = 96% (89%–99%) | 74/78 = 95% (88%–98%) | 57/78 = 73% (62%–82%) |
| US class label | all labelled (22) | 20/22 = 91% (72%–97%) | 20/22 = 91% (72%–97%) | 14/22 = 64% (43%–80%) |
| Current rating, e.g. `10(60)A` | all labelled (57) | 57/57 = 100% (94%–100%) | 57/57 = 100% (94%–100%) | 39/57 = 68% (56%–79%) |

Ranges are 95% Wilson intervals. Verdict: the `accurate` level reads the full number on 97% of these close-ups under either agreement rule, above the 90% bar. The `fast` level misses a quarter of numbers and should not be used for this; language correction adds nothing. The two agreed numbers it missed are a thin-print number split by dots, which Vision read only in part, and a utility plate on a dark background that Vision never detected. The two class labels it missed are an oblique shot with `CL` and `200` on separate plates, and a `CL` cut off by the frame edge.

Reading is not the hard part; finding the number is (question 5). On only 21 of 75 photos was the tallest recognized line with 4 or more digits the meter number; nameplates carry registers, serials, model codes and seal numbers.

### 2. Retake checks: only focus and size survive on the phone

| Problem | Check the phone can compute | Retake when | Evidence |
|---|---|---|---|
| Out of focus | Laplacian variance of the whole photo, shrunk to at most 1024 px | 6.63 or less | AUC 0.96; rejects 0 of 75 good photos. Reading holds to a blur σ of 0.04 × line height (94%) and fails at 0.13 (4%) |
| Number too small | line height of the ranking's top candidate | 33.9 px or less | AUC 0.86; rejects 2 of 75 good photos. On the true number's line the cut would be 12 px (96% read at 15 px, 77% at 12 px); the top candidate likely needs more because once the number is too small, a larger line takes its place |
| Glare | none found | – | on the true box the saturated share works (AUC 0.95), but on the top candidate it has an AUC of 0.55 and rejects all 75 good photos; the whole-photo saturated share rejects 47 |
| Number cut off | none found | – | the top candidate's gap to the frame edge has an AUC of 0.61 and rejects 37 of 75 good photos at its 95% cut |
| Hand shake | none found | – | reading survives streaks up to 0.2 × line height (93%), but every sharpness score either misses streaks (AUC 0.69–0.85) or rejects 21–37 of 75 good photos |

Verdict: only the focus check meets the criterion without a locator, and the size check with the phone's top candidate. Glare and framing checks work only on the true number's box: once glare washes out the number or the edge cuts it, the number usually stops being the top candidate (on degraded photos the top candidate was the number on 1,366 of 3,309 reads). "Rejects 0 of 75 good photos" is weak evidence: no real photo is near a threshold. The smallest label is 22 px, and the lowest whole-photo sharpness is 58.7 against a cut of 6.63. Even above every break, 0.7–2.6% of degraded reads failed anyway, which no photo check can prevent.

`results/sweep.md` has the full read-rate curves, every check's 95% and 80% thresholds, and the real-photo rejection counts.

### 3. A second pass rarely helps

Re-reading a crop around the top candidate recovered 3–4% of failed reads for blur, motion, glare and framing. For labels made too small it recovered 6% as cut and 11% when upscaled 2x (13% with either). Verdict: a retake beats a second pass; upscaling a small label is the only case worth adding. Combining two frames was not tested.

### 4. Barcodes confirm the number when there is one

| Photos | Barcode found | Decoded | Decode contains the meter number |
|---|---|---|---|
| All usable: 80 | 25 | 25 | 20 of 24 with a labelled number |
| US-style (CL class label): 22 | 9 | 9 | 8 of 8 with a labelled number |

Every barcode Vision found also decoded, and 20 of the 24 decodes on photos with a labelled number contain it, well above the one-third bar. The four misses encode a different identifier: a Hydro-Québec barcode carrying a second utility number, and QR codes on two Taiwanese smart meters and a Japanese meter carrying the maker serial or a product record.

### 5. Finding the number: no rule can fill it in unasked, and tap-to-confirm falls short

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

Held-out photos are the 33 even-numbered photos whose number Vision read; the rules were committed before they were scored. Verdict: both criteria fail. No rule reaches 95% precision, so the app cannot fill in the number unasked. The top three hold the number on 85% of held-out photos, short of 95%, so a tap-to-confirm screen alone would still send about one homeowner in seven back for a retake or a typed entry. Under the strict labels the top three hold it on 56 of 60 read photos (93%, 84%–97%), still short.

Ten photos went wrong: on seven the top three missed the number, and on three the barcode rule picked the wrong identifier. They split evenly between two causes:

- **Several real identifiers on one plate.** The rule picked another identifier printed on the meter: a maker serial next to a utility plate, a second barcode, or a `SERIAL#` line. Reader 1 chose which identifier is the label, so these misses depend on that choice. Base should say which identifier it uses for each utility, or accept any printed identifier.
- **Vision split the number or merged a neighbour into it.** A prefix or digits landed in a separate observation (a number printed like `S12 A345 678` read as `12A345` and `678`), or a neighbouring character joined it, so the exact number never appears as a candidate.

Exploratory, not held out: on US-style meters, chosen as a subgroup after the held-out scoring, the barcode rule was right on all its picks, 5 of 5 on the odd-numbered photos the rules were written on and 3 of 3 held out (44%–100%). Three picks cannot support filling in the number without asking.

## For the app: what to port

Recommended flow, from the results above: read the close-up, then show the three best candidates, with a barcode-confirmed candidate ranked first, and let the homeowner tap the number or "none of these". The tap confirms the number, so a confirmed number needs no readability check. Before showing candidates, block a photo that fails the focus check. After "none of these", ask for a retake, and use the size check to say "move closer". There is no measured signal for glare, framing or hand shake, so those prompts can only be general advice.

Every check runs on the full-resolution photo after applying its EXIF orientation. "Luma" is the 8-bit image L = 0.299 R + 0.587 G + 0.114 B. Boxes are Vision's normalized `boundingBox`, converted to a top-left origin. `src/meter_eval/retake.py` implements the same definitions, and `tests/test_retake.py` holds hand-computed cases and a pinned value for the resize.

| Check | Input | Formula | Retake when |
|---|---|---|---|
| Out of focus | whole photo, luma | shrink so the long side is 1024 px, bilinear with antialiasing as PIL does, leaving smaller photos as they are; convolve with the 4-neighbour Laplacian [[0,1,0],[1,−4,1],[0,1,0]] over interior pixels; population variance | 6.63 or less |
| Number too small | top candidate's box | box height × photo height in pixels | 33.9 px or less |
| No number | ranking | no candidate at all | always |

Finding the number: read with `VNRecognizeTextRequest` revision 3, `.accurate`, `en-US`, language correction off, `minimumTextHeight` 0, and run `VNDetectBarcodesRequest` revision 4 on the same image. Build candidates and rank them by the score in the method section. `src/meter_eval/locate.py` is the reference for the tokens, features and score.

## Field test before trusting the thresholds

Commons photos are processed JPEGs from many cameras, not frames from the app's camera pipeline. Sharpening, noise reduction and tone mapping change sharpness values, so the focus threshold may move in the app; the size threshold depends on geometry and the ranking. Take these close-ups of one real meter with the app's own capture path (or the iPhone camera if the app is not ready), then run `uv run python -m meter_eval.fieldtest PHOTO_DIR --number "<number as printed>"`. As in the app, its checks use the ranking's top candidate; `--number` only scores the outcome. It prints each photo's read result, rank and check values, and counts retakes asked for photos that read and photos accepted that did not.

| Threshold | Photos to take | It holds if |
|---|---|---|
| Out of focus | three with focus locked on a distant background, one from 5 cm (inside the minimum focus distance), three sharp | blurred photos score 6.63 or less and fail to read; sharp photos score far above |
| Number too small | square to the meter from 15, 30, 50, 80 and 120 cm | photos whose top candidate is 34 px or taller read, and the number is in the top three |
| Glare (no check) | the flashlight of a second phone held beside the camera at 0°, 20° and 45°, or direct sun, with the reflection on the number | records how often glare alone breaks reading and whether the number drops out of the top three |
| Cut off (no check) | the frame edge cutting a quarter digit, half a digit and one whole digit | records whether a cut number ever appears as a confirmable candidate |
| Hand shake (no check) | three in shade while sweeping the phone sideways during capture | records how often shake alone breaks reading; if it does, gate capture on gyroscope motion instead of an image score |

## Checking the labels by hand

Running `make review` builds `~/house-scanning-data/meter-closeup/review.html` outside git, because it shows the plaintext meter numbers. Open the file in a browser. Each whole photo appears first, beside the number the AI readers settled on, with a zoom on the line Vision read below it, so the reviewer sees every identifier on the plate. Press K to keep the number, or F to type a correction and Enter to save it. Progress stays in the browser, so the page can be closed and reopened. "Download answers" saves a CSV. `uv run python -m meter_eval.review ingest <csv>` stores it for `python -m meter_eval.labels`. A kept number then counts as agreed under both rules; a corrected one replaces the label but is not counted as agreed until someone keeps it. Rerun the tables after that.

## Rerun

Needs macOS with Xcode 26 (Swift 6), uv, and the HMAC key. From this folder:

```sh
make images   # download the 83 photos to ~/house-scanning-data/meter (set METER_DATA to change)
make q1       # results/clean.md and results/clean_per_image.csv, about a minute
make sweep    # the degraded reads, two processes of up to 2 GB, about 25 minutes
make q2       # results/sweep.md and results/sweep_rows.csv
make q45      # results/locate.md and results/locate_per_image.csv, about a minute
make review   # the label review page, outside git
make check    # lint and unit tests
make leakcheck
```

Every number in this README comes from one of those results files. `manifest.csv` and `identifier_digests.txt` are the committed output of `python -m meter_eval.labels`, which merges the readers' plaintext labels from the data directory. The sweep tags each row with the digest of the label it was scored against: after a label changes, `make sweep` sweeps that photo again and `make q2` ignores the stale rows.

## Limits

- The labels come from AI readers (see above), and reader 1 chose which identifier counts as the meter number, which decides five of the number-finding misses.
- Commons photos are mostly deliberate, well-lit close-ups; homeowners' photos will be worse, so 97% is likely optimistic. US residential meters are a minority of the set, and class labels were read on only 22 photos.
- Degradations are synthetic transforms of real photos: one glare model, horizontal motion only, and no noise, low light, compression or perspective. Class labels were not swept; the thresholds are for meter numbers.
- The class-label matching rule was loosened after the first run, to ignore separators and read `×` as `x`; every first-run miss was one of those. The meter-number rule was not changed.
- Sharpness values are in grey levels squared on 0–255 images and depend on the camera's processing. Recheck the thresholds on iPhone captures before shipping them.
- macOS Vision stands in for iOS Vision: same API and revision, not verified on a phone.
- The number-finding rules were written on half of the photos after the author had read every photo while labelling, so the held-out half limits but does not remove fitting to this set. Its 33 photos give wide intervals.
- The branch history was rewritten on 2026-09-26 to remove real meter numbers that had been used as examples, and to replace unkeyed digests. Commits before that rewrite may still be reachable on GitHub by their old IDs.
