# Panel label readability

Installers check the main electrical panel's manufacturer, model and main breaker amperage. Some panel lines are known hazards: Federal Pacific Stab-Lok and Zinsco are both subjects of public safety notices. The main breaker's amperage matters for any battery install. If the phone can read a close-up of the panel label, a homeowner can answer with one photo instead of a form. This experiment set out to measure that on real, openly licensed panel photos, reusing the meter close-up tooling.

## Questions and pass criteria, set before the run

1. How often does Vision's `accurate` mode read the manufacturer, the model or series, and the main breaker's amperage? Each field is scored on the photos where both AI readers agree it is legible, under the strict rule (both readers transcribed the same text and were sure). One photo can replace the form if the manufacturer and the main amperage are each read on at least 90% of those photos; below 70%, keep the form.
2. Can a simple rule map the recognized text to a manufacturer from a small public list, including the known-hazard lines? Precision (the named manufacturer is right, among photos where the rule names one) and recall (over photos with an agreed manufacturer) are reported on held-out photos. The rule may name a manufacturer without asking the homeowner if its held-out precision is at least 95%. To limit fitting, the rules are written using only odd-numbered photos and committed before the even-numbered ones are scored.
3. Do the meter close-up's blur and too-small checks transfer to panel labels? They transfer if, on the same controlled degradations of the panel photos, the panel's own 95% break-point threshold for each check is no stricter than the meter's (whole-photo sharpness 6.63; top-candidate line height 33.9 px). Otherwise the panel needs its own thresholds, which are reported.

If fewer than about 40 usable openly licensed photos exist, the experiment stops there and reports what was searched.

## Result: stopped, too few photos

There are not enough openly licensed photos of residential panel labels to answer these questions. None of the three was measured.

| Photos examined at full resolution, duplicates removed | 67 |
|---|---|
| Any of manufacturer, model or amperage legible | 19 |
| Manufacturer and a model or amperage legible | 9 |
| All three legible | 6 |

`uv run python -m panel_eval.screen` regenerates these counts from `screened.csv`, which lists every examined photo with its URL, license, author and the per-field call. The calls were made by one AI reader (Claude Opus) looking at each photo at its stored resolution, so treat the counts as approximate. Even so, the lenient count is under half the 40-photo bar. The 9 photos also overstate the pool: two show the same panel, and one is an Indian moulded-case breaker, not a US residential panel. That leaves 7 distinct US panels.

The known-hazard lines are almost absent: one Federal Pacific Stab-Lok panel, found twice, and no Zinsco panel. Precision and recall for naming a hazard line cannot be estimated from one example.

As an anecdote and not a measured rate: on the 8 legible US photos, Vision read the manufacturer or line name on 6 (Federal Pacific and Stab-Lok, Frank Adam, Square D QO twice, GE, Square D). It read the amperage text on 4 ("100", "100A", "Mains 100 A Max", "125"). It read nothing useful on the Siemens main breaker, and garbled the Square D Multi-Breaker plate.

## What was searched

On 2026-09-26, filtered to CC0, public domain, CC BY and CC BY-SA:

- **Wikimedia Commons.** The file search for each of 20 queries in `src/panel_eval/sources.py` (for example "breaker panel", "load center", "Federal Pacific", "Stab-Lok", "Zinsco", plus maker names with "breaker panel"), and the `Square D` and `Square D circuit breakers` categories. There are no Commons categories for US residential panels, load centers or breaker boxes; the related categories (`Distribution boards`, `Circuit breakers`) hold mostly European DIN-rail boards and industrial gear.
- **Openverse** (openly licensed images indexed from Flickr, Commons and others): the same 20 queries at up to 100 results each, then every accessible page of 11 core queries, 1,808 results in total. The anonymous API stops at 240 results per query, so the long tails of "electrical panel", "fuse box", "load center", "circuit breaker" and "service panel" were not reachable.

The first pass returned 1,476 unique results and the deeper Openverse pass 1,356 more, about 2,800 in all. Screening titles and about 850 thumbnails left 78 photos to download at full resolution; removing 11 duplicates left 67. Most results are aircraft and ship panels, European consumer units, industrial switchgear, substations, car fuse boxes and diagrams. Most US residential panel photos are wide shots of wiring in which no label text is legible; Flickr copies in Openverse are mostly 1024 px.

## What would unblock it: photos to take on field day

The questions can run on the team's own photos, kept in `~/house-scanning-data/panel/images` and never committed, like the meter photos. The pre-set bar needs about 40 panels, each with the photos below. Ask the homeowner's permission first.

| Photo | Framing | Answers |
|---|---|---|
| Door label | the label inside the panel door, filling the frame, straight on | manufacturer, model or catalogue number, rated amperage |
| Main breaker | the main breaker handle and its rating, from about 20 cm | main amperage |
| Deadfront | the whole cover with the door open, including any brand badge or series name | manufacturer and line (Stab-Lok, Zinsco and other hazard lines show their name here) |
| Context | the panel and its surroundings from about 1 m | lets a reader check which panel the close-ups belong to |

- Take each close-up the way a homeowner would, handheld with the phone's own camera, not with a tripod or macro lens. Question 3 then degrades these photos under control, as the meter sweep did, so no deliberately bad shots are needed.
- Include several homes built between about 1950 and 1985. Federal Pacific Stab-Lok and Zinsco panels were installed then, and at least a few are needed to score naming them.
- Frame out, or cover before shooting, anything that identifies the home: inspection stickers with addresses, handwritten names in the circuit directory, and the meter's serial number.

Sources this search did not use are a second option. Unsplash and Pexels photos are free to use but not CC-licensed, and whether they count as "openly licensed" is the team's call. US government works are public domain, for example CPSC recall notices, but those show individual breakers rather than panel labels. Home-inspection sites have many panel photos but are not openly licensed.

## Rerun

```sh
uv run python -m panel_eval.sources find   # candidates.csv in ~/house-scanning-data/panel
uv run python -m panel_eval.screen         # the counts above, from screened.csv
uv run pytest -q
```

`meterocr/` is a copy of the meter experiment's Vision reader, kept so this folder stands alone once the team has photos.
