# Live survey research: findings and handoff

September 26, 2026. Research stopped at the user's request. This report packages the completed work, useful implementation proposals, and remaining validation gaps. It is a research handoff, not a production-readiness or installation-accuracy claim.

**Recommendation: build a hybrid evidence loop around native capture.** Use Swift, ARKit and RealityKit for the open camera, pose tracking, photo selection and immediate guidance. Save each useful original photograph with its own calibration and pose. Let asynchronous services perform heavier recognition and reconstruction, then evaluate requirements with explicit evidence and uncertainty. A complete photorealistic house model should not block a useful, source-backed answer.

## What was achieved

| Area | Completed work | Practical outcome |
| --- | --- | --- |
| Camera and capture | Compared native iOS, Android, browser and native-module paths; typechecked relevant ARKit still-capture and guidance APIs; built a durable capture-admission prototype | Native iOS is the leading integration path. Progress must follow the returned, accepted, durably saved photograph—not the preview that triggered it |
| Coverage and guidance | Explored surface coverage, unknown space, task evidence, next-view policies and screen projection; exercised synthetic policies and actual native coverage code | Separate **where to move**, **where to aim**, and **what evidence is still missing**. Geometry revisions can invalidate earlier coverage |
| Reconstruction and visualization | Audited classical, learned batch, streaming and phone-depth alternatives; ran bounded DA3, MoGe, Apple depth and COLMAP probes | Several components run locally, but none establishes exterior measurement accuracy. Keep fast local geometry and slower reconstruction revisions separate |
| Recognition and association | Tested OCR/barcodes, box trackers, image correspondence and causal point tracking; built a revision-aware association prototype | Recognition confidence and a persistent tracking ID do not prove the correct equipment or exact label value |
| Architecture and integration | Checked camera/calibration conversions, evidence admission, reset races, export/version semantics and deployment limits | Preserve originals and coordinate epochs; use resumable object storage separately from compact placement requests |
| Reviewable implementation | Published two standalone Python prototypes and two isolated Swift patch proposals; existing camera-conversion work remains in [PR #9](https://github.com/SamGu-NRX/house-scanning/pull/9) | Useful work is available for selective integration without changing teammates' application branches |

The detailed [options and resources](research/2026-09-26-options-and-resources.md) retain alternatives. The [experiment evidence](research/2026-09-26-experiment-evidence.md) records positive, negative, blocked and unrun outcomes.

## Recommended flow

```mermaid
flowchart TD
    A[Open camera and capability checks] --> B[Local tracking and image-quality checks]
    B --> C[Coverage and missing task evidence]
    C --> D[Move cue or aim cue]
    D --> E[Select a useful still]
    E --> F[Assess actual returned image and metadata]
    F --> G[Durably admit original and evidence]
    G --> C
    G --> H[Resumable upload to object storage]
    H --> I[Asynchronous recognition and reconstruction]
    I --> J[Versioned geometry and sourced observations]
    J --> K[Deterministic checks with uncertainty]
    K --> L[Supported result or specific missing evidence]
    L --> C
    J --> M[Inspectable 3D preview with original photos]
```

Local feedback continues while uploads and workers are pending. Capture completion, upload completion, analysis completion and assessment completion are separate states. A newer result is accepted only when its evidence and coordinate dependencies are still valid.

## Findings that change the design

1. **A view is useful only after the actual still is assessed and saved.** A preview may look sharp while the returned still is late, blurred, from another pose, or associated with an obsolete task. The capture prototype makes admission and progress transactional, preserves original evidence, and prevents old coordinate epochs from silently satisfying current spatial requirements.

2. **Fog of war needs more than the path the customer walked.** Surface coverage, unknown/occupied space and required close-up evidence need separate records. A missed ray in an incomplete mesh means unknown. It does not establish open space or a safe route. If ground or wall geometry changes, dependent coverage must be recomputed or invalidated.

3. **Coverage can become stale in the current native implementation.** At the inspected source commit, changing only the ground height retained 14 covered cells; a fresh map with the same cameras and new height had zero covered cells. This is a reproducible software-state inconsistency, not a sensor-accuracy result. The published replay helper is a limited, unrun proposal; its refusal of an unresolved horizontal cell shift still needs an integration policy.

4. **Reconstruction updates can revise earlier geometry.** Adding a fourth image to the DA3 batch changed earlier depth estimates: 3.06% mean absolute relative revision before alignment and 6.51% after it. These describe change, not improved accuracy. Measurements and results derived from revised geometry need revalidation.

5. **Tracking needs a recovery path and independent context checks.** BootsTAPIR processed all 175 frames of one public indoor book sequence. Only **457/1,392** point-frame opportunities were both marked visible and inside the object mask, despite **457/458** containment among visible outputs. There were 77 frames with no visible query. Mask containment cannot establish exact point correspondence or equipment identity. This Mac run also does not establish real-time phone performance.

6. **OCR confidence is insufficient for exact identifiers.** Synthetic native and portable OCR checks produced identifier mistakes at high confidence. Preserve original crops, text spans and field associations; keep unreadable or conflicting values unresolved. Two inspected real photographs supplied observations, not an independently adjudicated accuracy benchmark.

7. **Use separate transport for original photographs.** Vercel documents a 4.5 MB Function request/response envelope. Send original media to a suitable storage endpoint and submit compact scene/placement data separately. Live checks covered only health and schema reads; no upload recovery or placement service was validated. [Vercel limit](https://vercel.com/docs/functions/limitations#request-body-size)

## Implementation delivered

| Artifact | What it contains | Validation boundary |
| --- | --- | --- |
| [Capture admission](../experiments/research-handoff/capture-admission/README.md) | SQLite prototype for request/returned-still separation, atomic evidence admission, epoch/revision checks, crash rollback and acknowledgments | Synthetic bytes and supplied assessments; no camera, real upload or production storage integration |
| [Equipment association](../experiments/research-handoff/equipment-association/README.md) | State machine separating observations, nominated equipment, context revisions and reviewed label associations | Synthetic in-memory transitions; no physical identity or image-recognition validation |
| [Native patch proposals](../experiments/research-handoff/native-proposals/README.md) | Small current-source reset patch plus a separate ground-coverage replay helper proposal | Reset patch passed nine paired harness cases; ground helper remains unrun. Neither was applied to the app |
| [Camera metadata adapter, PR #9](https://github.com/SamGu-NRX/house-scanning/pull/9) | Camera coordinate conversion and input-validation experiment | Existing mathematical tests; not physical calibration or field accuracy |

The public package contains original reusable code, synthetic tests, patch proposals and curated results. Downloaded datasets, model weights, build caches, private source material and detailed local run receipts remain outside Git. Historical failures are retained locally rather than silently replaced by later passes.

Publication validation: the exported capture-admission suite passed **26 tests** and equipment-association suite passed **11 tests** on Python 3.13.7. Their READMEs contain the exact commands. Python syntax, JSON, relative document links and patch hashes were checked; the published implementations match the reviewed source. The app/server/web files were not changed or built in this handoff.

## What remains unresolved

**The largest gap is a real-phone session on representative exterior geometry with independently measured dimensions.** Desktop API checks and synthetic controls cannot answer whether still capture disrupts tracking, whether arrows remain aligned, or whether a phone can sustain the workload without thermal or battery problems.

The next useful work, if resumed, is:

1. **One small field capture:** ordinary supported iPhone first, optional LiDAR comparison. Keep per-image pose, calibration, original bytes and coordinate epochs. Record interruptions, bad captures and recovery—not just the happy path.
2. **Independent geometry checks:** measure identified endpoints with a separate method. Reserve held-out distances when fitting scale or alignment. The acquired TUM reference sequence is ready for a fixed depth-consistency diagnostic, but that diagnostic and model evaluation were not run.
3. **Focused guidance validation:** test move-versus-aim behavior, viewport/orientation changes, stale results and geometry revisions. Observe whether customers follow the cues and whether missing evidence remains visible.
4. **Durable end-to-end integration:** review the isolated reset patch, implement qualified observation replay, test interrupted/background uploads, and bind each assessment to exact image, scene and rules versions.
5. **Representative recognition and identity evaluation:** use adjudicated labels and per-point correspondence/visibility truth. Compare abstention and wrong associations as well as successful reads.

Keep browser coaching, ARCore, alternate reconstruction models and simpler evidence-first outputs available when device reach, measured quality or deployment costs change the tradeoff. No permanent model winner or whole-house accuracy claim was established.
