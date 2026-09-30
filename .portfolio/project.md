---
# kgu.one builds this project's page from this file (https://kgu.one/projects/basescanning).
# When a change alters what the project does, its results, awards, stack or links,
# update this file in the same change. Rules:
# - Facts only, each one backed by this repo, the resume or a public source.
# - No em dashes and no middle dots.
# - line: at most 120 characters, ending in a period. What someone does or gets,
#   then one mechanism. No adjectives.
# - The paragraph after this header: 50 to 80 words, first person. What it is, who
#   used it, the hard part, one fact.
title: BaseScanning
kind: project
date: 2026-09
line: An iPhone app that scans the wall by your meter and shows, in AR, where a home battery can go.
award: 1st, Most Commercializable, Base x AITX
badge: 1st
stack: [Swift, ARKit]
links:
  - label: Site
    href: https://house-scanning.vercel.app/
  - label: Code
    href: https://github.com/SamGu-NRX/BaseScanning
---

Base Power used to place its home batteries from photos homeowners sent in, and a photo can’t show what sits outside its frame. Our iPhone app guides one walk along the meter wall, the server rebuilds that wall in 3D and checks it against every placement rule, and the answer comes back in AR. It never calls a spot clear if the camera didn’t see it; it asks for that view. Four of us built it in a weekend.
