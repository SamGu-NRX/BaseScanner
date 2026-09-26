# House scanning: plan, decisions and evidence

A homeowner scans the outside wall around their electric meter with an iPhone. The server works out whether a Base Power battery fits there and where, and the app shows the spot in AR. Success means one capture session gives Base enough to decide, with no follow-up photos. A person can still review any result.

Base's survey starts today from customer photos, which have no scale, can't show whether two things share a wall, and miss whatever sits just outside the frame. An AR session gives every photo a position and a real scale, and the app knows what it hasn't seen while the homeowner is still there.

The work is three problems: guide the homeowner until the phone has captured everything the rules need, turn the photos and their metadata into a 3D model, and check that model against the placement rules. Full-house scans, roofs and Android are out of scope. Each component's README is the source of truth for that component and wins where it differs from this file.

## Two teams

- **Client team.** Sam with AI agents; Aiden films video and gathers sample datasets. The app in `ios/` builds a live 3D map on the phone, with a haze ("fog of war") over what it hasn't seen, and guides the homeowner until everything the rules need is covered. Guided capture is in PR #10 and the live map in PR #21. The app sends a capture packet: photos, camera poses, intrinsics, motion-sensor readings, LiDAR depth and mesh when the phone has LiDAR, and the homeowner's marks. `packet/README.md` (PR #22) specifies it and lists what the app records today. For now the app uploads only its measurements, `scene.json`, and exports the full packet on request.
- **Server team.** Hunter with his agents. The packet goes in, a 3D model comes out, and the rules are checked on it. Starting points: the rules engine and API in `server/` (PR #11), the reconstruction worker in `recon/` (PR #20), the evals in `experiments/evals/` (PR #12), Hunter's research handoff (PR #18) and his [live-survey design](05-live-guided-survey-hld.md).

## Decisions

- **Guided AR capture, not a video processed later.** Photogrammetry alone (COLMAP, splats) has no scale, is slow, and struggles on blank siding; COLMAP's own tutorial says to avoid texture-less walls. The packet carries ARKit's poses and any LiDAR depth, so the server's model starts at real scale.
- **3D modeling stays central,** with LiDAR and the phone's poses supplying scale, because learned depth alone is too rough at edges.
- **Plain code decides placement; models build geometry and recognize things.** The engine unrolls the walls into one line, `s`, in feet from the meter (negative to the left), slides the battery's footprint along it in 2 in steps, and checks each rule as an interval overlap or a polygon distance.
- **Every check answers PASS, FAIL or UNSURE.** A check passes only when its margin beats the measurement's error and fails only when it misses by more than the error. Anything else is UNSURE, including a check on an area nobody observed, and the answer names the view that would settle it.
- **Rule values live in rules files, each with its source.** `server/rules.yaml` (PR #11) holds the public values and two labeled placeholders (pool 10 ft, driveway 5 ft); Base's values load from a git-ignored private file. Battery sizes live there too, because models differ: Base Core is 39.5 in tall on a 30.68 × 22 in footprint, and older units are 3 × 3 ft.
- **Native iOS only.** Expo has no first-class ARKit support, and capture needs mesh export, per-frame pose and lens data, and mesh raycasts.
- **AR results hang off the meter's anchor, with `.gravity` alignment.** ARKit corrects anchors as tracking improves, and drift runs about 2 cm a second. `.gravityAndHeading` depends on the compass, which developers report off by up to about 176° near a house.

## Conventions the code relies on

- `capturedImage` is landscape, as the sensor reads it, and the intrinsics match it. Save it unrotated. Any rotation must also rotate the intrinsics and every image-space annotation. Gemini, the box detector (Claude's docs call its coordinates approximate), returns `[ymin, xmin, ymax, xmax]` on a 0 to 1000 scale, so apply EXIF rotation before inference and before casting. Depth maps are 256 × 192, so scale the intrinsics down to match.
- ARKit camera space is x right, y up, looking down −z, with image v growing downward. The ray through pixel (u, v) has direction ((u − cx)/fx, −(v − cy)/fy, −1), rotated by the camera-to-world transform.
- Keep a frame when the phone has moved 0.5 m or turned 15° since the last one kept.
- Mesh vertices are local to their `ARMeshAnchor`: multiply each by the anchor's transform while copying it out, and never write back into ARKit's buffer. Set `automaticallyConfigureSession = false`, or RealityKit turns mesh classification off.
- On the mesh, the gap to a facing fence is a ray straight out from the wall at 1.5 ft high, and headroom is a ray straight up from 1 ft out. The mesh has holes, so cast a small fan and take a robust minimum. LiDAR reads from about 0.5 m to 5 m, so capture stands 1 to 3 m from the wall, and a miss beyond 5 m is unknown, not open.
- Default error bars are 0.3 ft for an AR tap, 0.5 ft for the LiDAR mesh and 1.5 ft for a position from photo detection. They are untested estimates. The server adds 0.16 ft per foot along the wall from the meter, from measured ARKit drift.

## Evidence so far

Public datasets with laser-scanned or surveyed ground truth. Sources: `experiments/evals/README.md` (PR #12), `recon/HANDOFF.md` (PR #20), `experiments/meter-closeup/README.md` (PR #16) and `experiments/panel-label/README.md` (PR #17).

- **Tracking.** A current iPhone (14 Pro Max, MARViN dataset) stayed inside the server's allowance: p90 position error 8.6, 13.4 and 18.5 in after 10, 20 and 30 ft, against 19.2, 38.4 and 57.6 in. That phone has LiDAR, and MARViN's reference may be scaled to its tracking. A 2018 iPhone 6s (ADVIO) ran two to three times over, partly from noise in that dataset's reference.
- **Learned depth.** A model's own scale is 4 to 12% off. Rescaled with the phone's poses, walls come within about 5 in at p90 at a realistic 2% pose error, and 2.8 in with exact poses. Edges, where clearances are measured from, stay at 8 in or worse. MapAnything's scale shifted with input resolution.
- **Reconstruction worker.** On the ETH3D building, wall p90 is 2.1 in with a laser scan standing in for LiDAR and 2.8 in from photos only, on different walls.
- **Coverage.** The app's first coverage map claimed 1.1 ft of a 19.3 ft wall that no photo saw. Requiring several view angles fixed that but dropped 6 to 8.5 ft of good wall; a depth test on LiDAR phones fixed it cleanly. The reconstruction worker, checked against depth, claims at most about 0.46 ft.
- **Meter reading.** Apple's on-device text recognition read the full meter number on 71 of 73 real photos but found the right line on only 21 of 75, because nameplates carry several numbers. A barcode held it on 20 of 24 photos that had one, and a list of three candidates held it on 85% of held-out photos. So the app offers three to tap, barcode match first, and asks for a retake when the photo is blurry or the number too small.
- **Panel labels.** Untested: 7 open photos of US panels exist, against the 40 the test needs.
- **World models.** Not evaluated yet.

## Open questions

- **Clearance values.** [04-prior-art-and-codes.md](04-prior-art-and-codes.md) has the public values with their citations. Base's own values go in the private rules file, along with which number on the meter plate Base needs.
- **Disconnect box.** Does the install add a battery disconnect beside the meter? Base's public pages mention a wall-mounted transfer switch and a battery disconnect.
- **The 3D path.** Traditional reconstruction fused with LiDAR, learned depth rescaled with the phone's poses, or world models, which produce a whole 3D scene from photos or video. The winner needs real scale, edges within the error allowance, and a record of which parts it observed and which it filled in.
- **Accuracy on our phone.** Nothing above ran on our phone. The field test uses a current iPhone without LiDAR, the Measure Lab build (PR #7), a 30 ft tape and a real meter wall, following `experiments/evals/field/FIELD_SHEET.md` (PR #12); a dry run recovered a planted 1.5% scale error. It also checks the default error bars. LiDAR on siding in midday sun is untested too.
- **Pool and driveway.** Their checks need up to 13 ft of photographed ground. The alternative is one yes-or-no question, recorded as the homeowner's answer.
- **Hidden wall.** Something standing in front of the wall can hide it, and nobody owns that check yet. One proposal: the app shows the homeowner the photo of the chosen spot and asks, and runs the depth test on LiDAR phones.
