# Field sheet: one wall, one tape, one number

Adds to PR #7's [one-hour protocol](https://github.com/SamGu-NRX/house-scanning/blob/t3/measure-lab/experiments/measure-lab/README.md#one-hour-outdoor-protocol); follow it for everything not listed here. Measure Lab can't name measurements. It numbers them M1, M2… in the order you save them, and the map expects the order below.

## Bring

- An iPhone **without LiDAR** with Measure Lab. In the Session sheet, LiDAR must say No.
- A tape of at least 35 ft; the longest span is 30 ft.
- Painter's tape, a marker and chalk.
- A second phone for notes, with this sheet open.

## Mark (painter's tape)

1. **A and B** at the wall's base, 30 ft apart. The opening, the meter and S1/S2 must all lie **between** A and B, or the app flags them and they don't count.
2. **S1 and S2**: two crosses on the wall at chest height, 3 to 10 ft apart.
3. **X** on paving, about 6 ft from the wall.
4. **F** at the base of the fence or wall facing yours, straight across from the wall.
5. **L1 and L2** on paving, 20 ft or more apart, for example along the fence.

## Tape (write readings as the tape shows them: `30 0 1/8`)

| Name | From → to |
| --- | --- |
| span-30-ab | A → B, along the base |
| span-30-ba | B → A again: a second, separate reading |
| scale-ref | S1 → S2 |
| opening-width | the opening's left frame edge → its right frame edge |
| sill-height | the ground at the wall → the sill |
| meter-height | the ground at the wall → the meter's bottom edge |
| facing-gap | the wall → F, square to the wall |
| overhead-height | the ground → the eave or beam corner |
| span-20 | L1 → L2 |
| (location) | F's distance along the wall from A |

## In the app (Session › New session)

Rules for every step:
- **Ground and Wall taps:** look down at the spot and wait until the ground covers it. A flagged wall contact flags everything on that wall.
- **Side-walk:** walk about 6 ft sideways and back, slowly, 6 to 20 ft from the wall, with the feature in view. Don't point at the sky.
- **Measure:** open Measure, set From and To, tap the **named quantity**, type the tape reading, then Save. The banner must say **"M# saved"** with the number shown here. If it says "abstention", write down why and carry on.

| # | Do | Measure |
| --- | --- | --- |
| 1 | Ground: X (P1) | |
| 2 | Wall: A (P2), walk the base to B, B (P3), then one more base point between them (P4) | |
| 3 | | **M1**: From P2, To P3, **Along the wall**, span-30-ab |
| 4 | On wall: S1 (P5), S2 (P6), side-walk | **M2**: the preset P5→P6, **Straight line**, scale-ref |
| 5 | On wall: opening left edge (P7), right edge (P8), on the frame, not the glass; side-walk | **M3**: the preset, **Along the wall**, opening-width |
| 6 | On wall: sill (P9) | **M4**: From P9, To **W1 · wall line**, **Height above ground**, sill-height |
| 7 | On wall: meter's bottom edge (P10), side-walk | **M5**: From P10, To W1, **Height above ground**, meter-height |
| 8 | Ground: F (P11), with the wall's base in view | **M6**: From P11, To W1, **Gap to the wall**, facing-gap |
| 9 | Two-view: overhead corner, step 3 ft sideways, tap it again (P12) | **M7**: From P12, To W1, **Height above ground**, overhead-height |
| 10 | Walk to the wall's far end and back, 6 to 20 ft out; then Ground: X again (P13) | **M8**: From P1, To P13, **Straight line**, tape `0` |
| 11 | Ground: B (P14), walk to A, Ground: A (P15) | **M9**: the preset, **Straight line**, span-30-ba |
| 12 | Ground: L1 (P16), walk, Ground: L2 (P17) | **M10**: the preset, **Straight line**, span-20 |
| 13 | Session › **Share session**, AirDrop the zip to the laptop | Note the phone model (Settings › General › About) and the iOS version |

**Went wrong?** Keep going. An extra point shifts the later P numbers, so pick From and To by their labels. An extra or wrong saved measurement shifts every later M number, so write down the actual M numbers and fix `session_measurement` in `map.json` afterwards.

## On the laptop (nothing else heavy running)

```sh
cd ~/"Programming Projects/house-scanning-evals/experiments/evals"   # or your checkout
D=~/house-scanning-data/evals/field/$(date +%F) && mkdir -p $D
cp field/survey.template.json $D/survey.json && cp field/map.template.json $D/map.json
# In $D/survey.json, replace each "FILL ft in" with the reading as text ("30 0 1/8"),
# and the candidate's location. Then, once per zip:
make field SESSION=$D/<session>.zip TRUTH=$D/survey.json MAP=$D/map.json
```

`make field` fills in the zip's sha256 and session id itself. The AR scale error is in `field_report.md` in the results folder it prints. Proven on a synthetic session with these templates: `make field-dryrun`.
