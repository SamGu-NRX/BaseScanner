# Public rules, code citations, prior art and licenses

Researched 2026-09-25 from public sources; Esri's imagery terms were rechecked on 2026-09-26. UNVERIFIED marks a claim nobody could confirm. Licenses change, so recheck one before building a product on it.

## What Base does today

- **Photo checklist, 9 photos** ([help page](https://help.basepowercompany.com/en/articles/10280641)): the meter close up with its number legible, the meter's surroundings from 10 or more steps back, the areas to its left and right, the adjacent wall corner to corner, behind the fence, the main breaker box, the main disconnect with its amperage readable, and the breaker box's surroundings. Base's engineering and installation teams review them and reach out within 2 days if they need more. Nothing public says whether AI is involved.
- **Placement rules** ([help page](https://help.basepowercompany.com/en/articles/10280705)): a 3 × 3 ft footprint about 36 in tall, within 20 ft of the meter and 1 ft of the wall, and 3 ft from gas meters, fences, AC units and other batteries. Not in front of meters, panels, solar equipment or windows. The meter is at most 6 ft up, and the meter and breaker box share a wall; the box can't be in a closet. 30 × 36 in of working space in front of the meter and panel. The transfer switch is about 13 in wide with 30 in of clearance, and the spec pages ask for 3 ft of wall for it, then 3 × 3 ft per battery. The main breaker is 100 to 200 A (150 to 200 A in Austin), and two batteries or solar need a 200 A panel. No concrete pad, because the base is integrated.
- **Hardware.** 25 and 50 kWh ground units, and Base Core: 39.2 kWh, 39.5 × 30.68 × 22 in, an 11 kW inverter, UL-listed ([pv magazine](https://pv-magazine-usa.com/2026/08/04/base-power-launches-39-2-kwh-u-s-made-base-core-home-battery-secures-1-billion-in-new-funding/)). A wall-mounted transfer switch and a battery disconnect; no public mention of a meter collar.
- **Review.** A Deployment Site Designer job post, removed in November 2025, describes people reviewing customer site photos by hand in CAD. Heavy lifting is split from electrical work so crews can do "20 homes in a day".

## Public rule values

The demo's `server/rules.yaml` (PR #11) uses these. Base's own values are private and never appear in tracked files.

| Rule | Value | Source |
| --- | --- | --- |
| Cable run from the meter | within 20 ft | Base's help page |
| Distance from the wall | within 1 ft | Base's help page |
| Gas meter or regulator | 3 ft | Base's help page; Austin Energy §1.9; Texas Gas Service |
| AC units, fences, other batteries | 3 ft | Base's help page |
| Doors and windows entering the home | 3 ft | IRC R328.4 |
| Working space at the meter and panel | 30 in wide, 36 in deep, 6.5 ft headroom | NEC 110.26 |
| Headroom over the battery | 6.5 ft | NEC 110.26, applied to the battery as a demo choice |
| Driveway, pool | none public | demo placeholders, 5 ft and 10 ft |

## Code citations

| Code | What it says |
| --- | --- |
| **NEC 110.26** ([ICC](https://codes.iccsafe.org/s/ISEP2021P1/national-electrical-code-nec-solar-provisions/ISEP2021P1-NEC-Sec110.26)) | Working space 30 in wide, or the equipment's width, by 36 in deep with 6.5 ft headroom, and no storage in it. Base's page says "30 in high × 36 in wide", probably a garbled version |
| **Austin Energy Design Criteria, Dec 12 2023** ([PDF](https://austinenergy.com/-/media/project/websites/austinenergy/contractors/designcriteriamanual.pdf)) | §1.9.2: 30 in wide, 36 in deep and 6 ft 6 in headroom at meters; socket center 30 to 72 in above ground; at least 1 ft from doors and windows; no meter within a 3 ft radius of gas meters, regulators or relief valves. §1.12: generation enclosures keep the 3 ft radius |
| **Texas Gas Service Meter Setting Requirements** ([PDF](https://www.texasgasservice.com/media/tgs/constructionservices/metersettingrequirements_tgs.pdf)) | Electric meters and outlets 3 ft from the regulator relief vent, and 3 ft from operable doors and windows |
| **IRC R328, 2021, from NFPA 855** ([ICC](https://codes.iccsafe.org/s/IRC2021P2/part-iii-building-planning-and-construction/IRC2021P2-Pt03-Ch03-SecR328)) | UL 9540 listed; outdoors or on exterior walls at least 3 ft from doors and windows; 3 ft between batteries unless UL 9540A testing allows closer |
| **NEC 706.15** | Battery disconnect within sight, and within 10 ft or lockable |
| **NEC 230.85** | Outdoor emergency disconnect; moved into 230.70 in the 2026 NEC |
| ComEd opening rules | UNVERIFIED; cite Austin Energy or Texas Gas Service instead |

## How others do it

- **Tesla Powerwall:** a guided self-survey on the phone, about 30 minutes, then photo upload and remote design.
- **Qmerit (EV chargers):** photo upload plus "Panel Insights", built with Schneider Electric, which reads breaker spaces and capacity from one panel photo ([announcement](https://qmerit.com/news/qmerit-deploying-ai-for-faster-safer-more-accurate-estimates-for-home-ev-charging-installations/)). The closest precedent for using AI only to recognize things.
- **SolarAPP+ (NREL):** instant automated code checks for solar and storage permits, the precedent for a rules engine in place of judgment calls.
- **Aurora Solar** has a Site Surveys API in beta ([docs](https://docs.aurorasolar.com/reference/site-surveys)); **Scanifly** uses drone photogrammetry.
- **Heat pumps:** Aira, Mitsubishi Ecodan and Alpha Innotec offer AR placement that is visual only, with no clearance checks. Fraunhofer ISE's Heat Pump PlanAR, reported 2026-09-23, scans indoor boiler rooms and optimizes placement: the nearest analogue, but indoors.
- **Hover** builds a measured exterior 3D model from phone photos and has a JSON API ([docs](https://developers.hover.to/reference/measurements-and-deliverables)), with turnaround likely in hours; useful as a later cross-check. EagleView sells wall, window and door measurements to enterprises. Polycam's API and Matterport's sandbox are closed to us, magicplan is indoor, and Canvas says it drifts outside.

Measurements from prior work: iPhone 12 Pro Max LiDAR on facades is within about ±6 to 8 cm of a total station, and iPad Pro LiDAR reaches about 5 m. A YOLOv5 meter-reading study read the counters 97% of the time and serial numbers only 63%.

What nobody else does: the whole loop outdoors, from metric AR capture through a solver that cites a code for each clearance to an AR preview. Heat-pump AR tools are visual only, and Fraunhofer's solver works indoors.

## Licenses and terms

**Aerial imagery.** Use StratMap or NAIP.

| Source | Terms |
| --- | --- |
| Google Maps, Street View | ToS §3.2.3(c)(vii) bans using the content to "train, test, validate or fine-tune" ML, and tracing building outlines from its imagery. The Solar API's §20.1 allows use "to determine the feasibility of installing energy systems"; whether running inference on it conflicts with §3.2.3(c) is UNVERIFIED |
| Mapbox | §1.5(ii) bans using it to "train, operate or improve" ML; operating includes inference |
| Esri World Imagery | Automated extraction only from an exported tile package, inside ArcGIS, with derived results for non-commercial use ([Esri](https://www.esri.com/arcgis-blog/products/arcgis-living-atlas/imagery/learn-to-use-ai-to-extract-information-from-world-imagery)) |
| TxGIO StratMap orthoimagery ([site](https://geographic.texas.gov/stratmap/index.html)) | Public domain; 6 in pixels inside Austin, 12 in elsewhere |
| NAIP, via Planetary Computer | Public domain; 0.6 m in Pflugerville (2022), 0.3 m in Naperville (2023). At 0.6 m a 3 to 5 ft driveway buffer is about 2 pixels |
| Overture buildings and transportation, OSM | ODbL: share-alike applies only if you publish a derived database. OSM tags driveways and pools on under 5% of homes. On 2026-09-25 Pflugerville had 14,675 houses, 149 driveways and 102 pools; Round Rock 9,223 houses, 476 driveways and 170 pools; Austin 302k buildings, 6,029 driveways and 3,339 pools |

**Models.** Before relying on one, check its weights' license separately from its code's.

| Status | Models |
| --- | --- |
| Noncommercial | MapAnything's default checkpoint (use `facebook/map-anything-apache`); Depth Anything 3 Giant and Nested (Metric Large, Base and Small are Apache-2.0); VGGT-Ω; UniDepthV2; Mapillary-Vistas Mask2Former weights; Molmo 2 |
| Restricted or unclear | Depth Pro (Apple personal-use grant); SAM 3 (custom license, gated weights); HY-World 2.0 (custom community license); Metric3D v2 (files disagree); MoGe-2 weights (UNVERIFIED; code is MIT) |
| Copyleft | YOLO-World, YOLOE and Ultralytics (GPL or AGPL); pymeshlab (GPL-3) |
| Permissive | SAM 2, Grounding DINO, OWLv2, Qwen3-VL, zxing-cpp (Apache-2.0); Florence-2, supervision, Open3D, Stray Scanner (MIT); shapely (BSD-3) |

For recognition boxes, Gemini 2.5 Pro scored 13.3 zero-shot mAP on RF100-VL against 1.5 for GPT-5.

**Datasets.** The evals use ADVIO (CC BY-NC 4.0), ETH3D (CC BY-NC-SA 4.0) and MARViN (no license stated) only to measure accuracy, and never redistribute them. Get permission before any commercial use. For training data, Roboflow Universe has gas meter sets ([402 images](https://universe.roboflow.com/proba-vwwtl/gas-meter-recognition), [1.4k images](https://universe.roboflow.com/gas-meter-zbuni/gas-meter-g7kh6)) and electric meter sets ([wattwise](https://universe.roboflow.com/wattwise/electric-meter-wzeeg-zk5fd), [1,943 images](https://universe.roboflow.com/abhinav-kumar-do8z1/utility-meter-reading-dataset-for-automatic-reading-yolo-z0e1h)), and Open Images V7 labels windows and doors. No public data exists for window wells, and open photos of US breaker panels are scarce: PR #17 found 7 against the 40 its test needs.
