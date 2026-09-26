# Prior art, what Base does publicly, and code citations

Researched 2026-09-25. UNVERIFIED items are marked.

## What Base does today (public)

- **Photo checklist, 9 photos** ([help](https://help.basepowercompany.com/en/articles/10280641)):
  - Meter close-up (number legible), meter surroundings from 10+ steps back, area to the left, area to the right, the adjacent wall corner to corner, behind the fence.
  - Main breaker box, main disconnect (amperage readable), breaker box surroundings.
  - The "Base engineering and installation teams" review them and reach out within 2 days if more is needed. Nothing public says whether AI is involved.
- **Placement rules** ([help](https://help.basepowercompany.com/en/articles/10280705)):
  - Footprint 3 × 3 ft, ~36″ tall. Within 20 ft of the meter and within 1 ft of the wall.
  - 3 ft from gas meters, fences, AC units and other batteries. Not in front of meters, panels, solar equipment or windows.
  - Meter ≤ 6 ft up. Meter and breaker box share a wall; the box can't be in a closet.
  - 30 × 36″ working space in front of the meter and panel.
  - Transfer switch ~13″ wide with 30″ clearance (spec pages: 3 ft of wall for the transfer switch, then 3 × 3 ft per battery).
  - Main breaker 100–200 A (150–200 A in Austin). Dual batteries or solar need a 200 A panel.
  - No concrete pads needed (integrated base).
- **Hardware:**
  - 25/50 kWh ground units, plus **Base Core**: 39.2 kWh, **39.5 × 30.68 × 22 in**, 11 kW inverter, UL-listed ([pv-magazine](https://pv-magazine-usa.com/2026/08/04/base-power-launches-39-2-kwh-u-s-made-base-core-home-battery-secures-1-billion-in-new-funding/)).
  - Wall-mounted transfer switch + battery disconnect. No public mention of a meter collar.
- **Who reviews:** a Deployment Site Designer job post (removed Nov 2025) describes people reviewing customer site photos by hand, using CAD.
- **Operations:** heavy lifting is split from electrical work so crews can do "20 homes in a day".

## How others do it

- **Tesla Powerwall:** guided self-survey on the phone (~30 min), photo upload, remote design.
- **Qmerit (EV chargers):** photo upload + "Panel Insights" AI (with Schneider Electric) reading breaker spaces and capacity from one panel photo.
  The closest precedent for using AI only for recognition ([link](https://qmerit.com/news/qmerit-deploying-ai-for-faster-safer-more-accurate-estimates-for-home-ev-charging-installations/)).
- **Aurora Solar:** Site Surveys API, beta ([docs](https://docs.aurorasolar.com/reference/site-surveys)).
- **Scanifly:** drone photogrammetry.
- **SolarAPP+ (NREL):** instant automated code checks for solar and storage permits. The precedent for rules engines over judgment calls.
- **Heat pumps:**
  - Aira, Mitsubishi Ecodan and Alpha Innotec have AR placement, but it's visual only with no clearance checks.
  - **Fraunhofer ISE "Heat Pump PlanAR"** (reported 2026-09-23) scans indoor boiler rooms and optimises placement. The nearest analogue, but indoors.

## Products with APIs

| Product | What | Notes |
|---|---|---|
| **Hover** | measured exterior 3D model (walls, windows, openings) from phone photos | Real JSON API ([docs](https://developers.hover.to/reference/measurements-and-deliverables)); turnaround likely hours; cross-check later, not the demo |
| EagleView | aerial, plus wall/window/door measurements (2026-03) | Enterprise |
| Polycam | 3D capture | API Enterprise-only |
| Matterport | 3D capture | sandbox is demo models only |
| magicplan | RoomPlan-based | indoor |
| Canvas | 3D capture | says it drifts outside and gives no exterior elevations |

## Prior art

- iPhone 12 Pro Max LiDAR on facades: ~±6–8 cm against a total station.
- iPad Pro LiDAR range: ~5 m.
- AR layout research (OCTO+, CHI 2023): places virtual content only, no code compliance.
- Meter OCR (YOLOv5 study): counters read 97%, serial numbers only 63%.

## Why the rules exist (citations for `rules.yaml`)

| Code | What it says |
|---|---|
| **NEC 110.26** ([ICC](https://codes.iccsafe.org/s/ISEP2021P1/national-electrical-code-nec-solar-provisions/ISEP2021P1-NEC-Sec110.26)) | Working space 30″ wide (or the equipment width) × 36″ deep × 6.5 ft headroom; no storage in it. Base's page says "30 in high × 36 in wide", probably a garbled version |
| **Austin Energy Design Criteria (Dec 12, 2023)** ([PDF](https://austinenergy.com/-/media/project/websites/austinenergy/contractors/designcriteriamanual.pdf)) | §1.9.2: 30″ wide / 36″ deep / 6′6″ headroom at meters; socket center 30–72″ above ground; ≥ 1 ft from doors and windows. No meter within a 3 ft radius of gas meters, regulators or relief valves. §1.12: generation enclosures keep the 3 ft radius |
| **Texas Gas Service Meter Setting Requirements** ([PDF](https://www.texasgasservice.com/media/tgs/constructionservices/metersettingrequirements_tgs.pdf)) | Electric meters and outlets 3 ft from the regulator relief vent; 3 ft from operable doors and windows |
| **IRC R328 (2021, from NFPA 855)** ([ICC](https://codes.iccsafe.org/s/IRC2021P2/part-iii-building-planning-and-construction/IRC2021P2-Pt03-Ch03-SecR328)) | UL 9540 listed; outdoors or on exterior walls ≥ 3 ft from doors and windows; 3 ft spacing between batteries unless UL 9540A testing allows closer |
| **NEC 706.15** | Battery disconnect within sight, and within 10 ft or lockable |
| **NEC 230.85** | Outdoor emergency disconnect (moved into 230.70 in the 2026 NEC) |
| ComEd-specific opening rules | UNVERIFIED. Cite Austin Energy / Texas Gas Service instead |

## Pitch angle: what's new

1. **Nobody does the whole loop outdoors.** Metric AR capture, a code-cited solver and an AR preview. Heat-pump AR tools are visual only, and Fraunhofer's solver is indoors.
2. **Every clearance becomes a traceable check.** "Fails AE §1.9.2: 3 ft from gas" instead of a vision model's judgment. SolarAPP+ for battery siting.
3. **Enforced coverage fixes Base's stated photo failures:** obstructed or too-zoomed views, unreadable meter numbers.
4. **Recognition stays with AI** (Qmerit's model); **measuring stays deterministic.**

Be honest about the limits:
- LiDAR reaches ~5 m and is accurate to ~±6–8 cm, so add margins.
- LiDAR is only on Pro iPhones.
- Unit sizes differ between Base models, so keep them as configuration.
- Some calls stay human: how it looks, and judgment calls a camera can't settle.
