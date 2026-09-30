---
# kgu.one builds this project's page from this file (https://kgu.one/projects/basescanning).
# When a change alters what the project does, its results, awards, stack or links,
# update this file in the same change. Rules:
# - Facts only, each one backed by this repo, the resume or a public source.
# - No em dashes and no middle dots.
# - line: at most 120 characters, ending in a period. What someone does or gets,
#   then one mechanism. No adjectives.
# - The body opens with one paragraph of 50 to 80 words, first person: what it is,
#   who used it, the hard part, one fact. The site uses it as the summary.
# - The rest of the body is the full write-up, in plain Markdown (## and ###
#   headings, lists, emphasis, inline code, https links), at most 1,500 words.
title: BaseScanning
kind: project
date: 2026-09
line: Splat! Walk the wall by your meter with an iPhone, and a home battery lands in AR where it fits.
award: 1st, Most Commercializable, Base x AITX
badge: 1st
stack: [Swift, ARKit]
links:
  - label: Site
    href: https://house-scanning.vercel.app/
  - label: Code
    href: https://github.com/SamGu-NRX/BaseScanning
---

Base Power decides where a home battery can go from photos the homeowner sends in, and a photo can’t show what sits outside its frame. BaseScanning makes it one walk. You scan the wall by your meter with an iPhone, our server rebuilds that wall in 3D and checks it against every placement rule, and the answer comes back in AR. Four of us built it at the Base x AITX Talent Hackathon and won first place for Most Commercializable.

## Unseen means unsure

The rule we cared about most is about what the phone didn’t see. A stretch of wall nobody filmed might be bare, or it might have a gas meter on it, and the server has no way to tell. So it marks that stretch unknown and never passes a spot that depends on it. The app asks for that view instead.

Measurements get the same caution. The phone tracks its position by adding up its own movements, so error piles up the farther you walk from the meter, and every measurement carries a margin. Take the 3 ft rule for gas meters. At 4.5 ft, give or take 0.8 ft, the check passes. At 3.4 ft with the same margin it could go either way, so it comes back unsure, and a person or a better view settles it.

The machine learning models build the wall and name what’s on it, but they never decide whether a battery fits. A deterministic check against a separate rules file does that. The server slides the battery’s outline along every stretch of wall the phone saw, 2 inches at a time, and runs 13 checks at each stop, among them the meter’s working space, gas and AC clearances and the cable run. It answers `pass`, `reject` or `manual_review`, and anything it can’t settle goes to a person.

## My part

I built the iPhone app and the capture packet, the file the phone sends to the server, working with AI agents. ARKit anchors the meter, Vision reads its number, Metal hazes over the parts of the wall the camera hasn’t covered, and a RealityKit raycast places each tap. LiDAR helps when the phone has it, but the app doesn’t need it. Everything ends up in one `scene.json`. When the server finds a spot, RealityKit pins the battery to the real wall through the camera.

Hunter Carver built the 3D model and the rule checks. Aiden Johnston ran field tests on a real iPhone and fixed what they turned up. Shrey Suri wrote the README and drew its diagrams.

## What doesn’t work yet

- Most of the system still lives in open pull requests, guided capture and the rules engine included.
- Our first run on a real phone placed nothing. The app put both ends of the wall at the meter, which left the server a wall with no length to search.
- Our best tracking result came from an iPhone 14 Pro Max, which has LiDAR. An iPhone 6s drifted two to three times past what the server allows.
- Reading the meter number is only half solved. The phone read the text in full on 71 of 73 photos but picked the right line on only 21 of 75, because a nameplate carries several numbers. For now the app shows three candidates and the homeowner taps the right one.
- The pool and driveway distances are placeholders, because we couldn’t find public values.
