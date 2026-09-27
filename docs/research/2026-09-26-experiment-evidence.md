# Experiment evidence at research stop

September 26, 2026. This is a curated record of the completed investigation. Counts belong to the stated inputs and exact experiment, not a shared leaderboard. Most runtime work used an Apple M5 Mac with 16 GiB memory; no physical-phone performance result was established.

**Evidence levels:** source/API inspection establishes documented contracts; synthetic execution establishes behavior for constructed cases; real-image execution establishes output on those images; independent physical accuracy requires separate truth. These levels are not interchangeable. Successful audit of saved arithmetic is not a second model or field run.

## Capture, guidance and evidence handling

| Investigation | Observed result | Limit / consequence |
| --- | --- | --- |
| ARKit still-capture APIs | Corrected standalone Swift probe typechecked with SDK 26, including returned-frame pose, intrinsics, timestamp and image dimensions | Initial naming error preserved. No camera, concurrency, throughput or thermal validation |
| Native guidance APIs | SDK 26 orientation, projection and window geometry calls typechecked for an iOS 16 deployment target; newer overload negative controls failed as expected | No physical screen alignment. World projection and captured-image display transforms remain different contracts |
| Coverage replay | Synthetic path/frustum examples exposed false-completion cases and exercised unknown/recovery handling | Walking nearby and seeing a surface are different. Analytic scenes do not establish exterior performance |
| Next-view policy | 15 synthetic scenarios across four variants; 60 controls passed, with a separate saved-state/metric review | Five cases had explicit preference labels. Full dwell expiration, users and real navigation remain untested |
| Capture admission | Latest prototype passed 19 producer controls and seven independent regression controls after epoch, revision-race and malformed-ID counterexamples were fixed | Simulated image assessment and bytes. Actual SIGKILL rollback covers one controlled transaction point, not all storage failures |
| Export coherence | 50 expected synthetic outcomes; separate audit covered 408 records across 16 cases | Source identity, references and warnings were checked. Physical endpoints, exposure identity and calibrated uncertainty were not established |
| Camera adapter | Existing [PR #9](https://github.com/SamGu-NRX/house-scanning/pull/9): 14 tests and 100 rotation controls | Coordinate arithmetic and input validation, not device calibration |
| Network replay | 54 primary and 18 additional synthetic controls | Invented workload; no real network, throughput or battery result |

Published versions of the two reusable state prototypes have their own test instructions and export-validation results under [research-handoff](../../experiments/research-handoff/README.md).

## Actual native source findings

The following findings apply to inspected commit [`a39d0a503412d688dd151f628cdeebc00f8221b6`](https://github.com/SamGu-NRX/house-scanning/tree/a39d0a503412d688dd151f628cdeebc00f8221b6), not an automatically moving branch head. Teammates' source was read without modifying their branches.

### Reset and asynchronous completion

One Swift build and one extracted-engine harness run produced 18 observations: nine baseline/patch pairs. Four baseline schedules admitted obsolete storage work or published a close-up after reset/phase change. All nine patched cases matched expectations, including normal success/failure and independent draining of old/new save generations.

The current implementation already uses store epochs and a per-generation pending-save dictionary. The proposal preserves those improvements. It adds task-entry/post-await validity checks and ensures the captured generation drains on early return. An earlier, larger patch against an older source revision is historical and should not be applied wholesale.

This harness uses exact extracted engine methods with declared completion instrumentation, controlled storage and UI/framework doubles. It does not execute the full iOS app, actual current disk writes, JPEG decoding, camera, OCR or upload. The [published patch](../../experiments/research-handoff/native-proposals/README.md) requires integration review.

### Ground-height coverage invalidation

Untouched `Camera`, `WallFrame` and `CoverageMap` sources were compiled into a fixed synthetic probe. Raising ground height from 0 to 0.5 m left the existing map's **14 covered cells** and revision unchanged; rebuilding from the identical observations at the new height produced **zero covered cells**. A no-op update preserved the original state as expected. All 11 predeclared checks passed.

The upper wall samples moved outside both images, but cached row evidence remained associated with the previous sample positions. Merely incrementing a revision would not fix the evidence. A replacement map may also reuse an old numeric revision, so downstream publication needs an explicit update contract.

The proposed helper replays qualified cameras in their original acceptance order and retains skip annotations. It was **prepared only**, not compiled or executed. It refuses a nonzero pending horizontal cell shift, a limitation that can occur during normal anchor refinement. It is not a complete app fix, observation ledger or UI integration.

## Geometry and reconstruction

| Investigation | Observed result | Interpretation |
| --- | --- | --- |
| MoGeSmall ONNX | CPU compatibility and one small illustrative forward completed; postprocessing had 19 mathematical controls | Not a reconstruction-quality or phone benchmark; PyTorch/ONNX parity remained unresolved |
| MoGe single exterior image | Declared conditional depth discrepancy decreased from 53.6% to 29.9% between two token settings | One image; depth/range and field-of-view conventions remained unresolved. Do not treat as a reliable accuracy score or model ranking |
| DA3 synthetic compatibility | Three-view CPU/MPS outputs were finite; invalid metric-mode usage was identified and preserved | Compatibility only |
| DA3 real views | Three public real images produced 29,400 exported, unfused points in one CPU run; output and viewer data were reviewed | Supplied poses/scale, moving foreground and unresolved reference scan semantics prevent accuracy scoring |
| DA3 added view | Fourth-image batch changed 117,600 shared depth samples: 3.06% raw and 6.51% aligned mean absolute relative revision | Context and alignment changed together. Neither value means improvement or accuracy |
| Apple Core ML depth | One native Mac CPU prediction returned all 203,056 finite FP16 samples; packing/row-stride/output checks passed | This artifact divides each image's learned output by its own maximum. It is a relative cue, not meters; one stretched input and one run |
| COLMAP | Initial database/thread precondition failures retained; subsequent saved-feature continuation yielded 371 raw and 333 verified pair rows, **zero final 3D points** | No successful reconstruction. Correspondence and timestamp audits did not justify silently changing pose associations or rerunning |
| MapAnything | Source/weight-license audit and helper-only execution covering 11 behavior groups | No model weights or inference. Crop, camera conventions, units and output revisions need integration checks |
| TUM reference acquisition | Complete 211,008,272-byte archive acquired; 465 RGB, 454 depth images and 1,554 poses; 451 associated pairs; three fixed views admitted from metadata | Original archive/pose identities checked; visual inspection showed a flat printed-paper scene with blur. Depth consistency and learned-model evaluation remain **unrun** |

The TUM profile fixes intrinsics, depth scale, timestamps, pose interpolation and three metadata-selected views before evaluation. Its prepared diagnostic would compare all six directed view pairs without fitting calibration or discarding residuals. It was not executed before the stop request. A small indoor planar reference would still not establish exterior-house accuracy. [Publisher dataset documentation](https://cvg.cit.tum.de/data/datasets/rgbd-dataset)

Streaming claims also need precise interpretation: a stateful lower-level model can be wrapped by code that resets state; accepting chunks does not necessarily mean causal live input. MapAnything, LingBot, MoGe-3 and classical reconstruction remain alternatives in the [resource comparison](2026-09-26-options-and-resources.md).

## Recognition, tracking and association

| Investigation | Observed result | Interpretation |
| --- | --- | --- |
| Native OCR | 84 synthetic requests included exact-identifier errors at confidence 1.0 | Confidence saturation does not justify accepting an exact identifier |
| PP-OCR tiny | Same 21 synthetic inputs: 39/68 lines and 2/17 labels in the declared scoring contract | Different score meanings/timing and a source-derived adapter; not a field ranking |
| Vision 26 | 42 requests; document path 47/68 lines and 5/17 labels, with top-1 strings matching legacy on this set; smudge API ran | Synthetic inputs do not validate actual lens contamination or equipment text |
| Two real label photos | Native OCR yielded 19 observations, illustrating split/merged fields | Provisional readings, no independently adjudicated truth or accuracy rate |
| Native barcode | Two exact synthetic strings recovered; separate byte/segment analysis explained original raw-byte mismatches | Original comparison failure retained. No universal payload-format or equipment-identity claim |
| Vision box tracker | 175-frame book run: 160/174 later frames had zero box overlap despite persistent identity/confidence signals | One indoor sequence, initial annotation assistance; not a phone or residential test |
| ViTTrack box tracker | Same sequence: mean box IoU 0.40943 versus Vision 0.03681; 12 false updates counted zero, 43/162 accepted boxes had zero overlap | Better on this clip still includes confident wrong targets; runtime boundaries differ |
| Pairwise SIFT | Fixed 15-feature nomination against nine target views refused all for insufficient matches | No homography fitted; not a universal SIFT failure |
| LightGlue, nomination only | Nine fixed 15-by-500 feature pairs produced no matches | Exact saved features and author checkpoint; not the author's full extraction pipeline |
| LightGlue, full context | Same original source expanded to 500 features: 1,093 full-scene matches; only two matches originated in the fixed source nomination, both paired with frame 175 | Target-object membership was not verified; no correspondence truth or geometry fit. Scene agreement is not nominated-equipment agreement |
| Vision registration | Known synthetic warp returned confidence 1; none of eight declared coordinate families or inverse diagnostics met the fixed residual bounds; best RMS 8.587 px | Registration versus an unmodeled coordinate convention remained unresolved; not an API-wide defect claim |
| Equipment association | Corrected prototype passed 11 synthetic transition cases after independent review found a sibling-ticket race | In-memory state semantics, not physical identity, image resolution or authenticated review |

### Causal point tracking: useful signal, incomplete availability

BootsTAPIR at tapnet commit `730cda1c730877cfedbe01bf87fb1cadb78a565d` first passed strict checkpoint loading and two synthetic causal steps. It then completed one continuous CPU run over all **175 original book images**, with eight fixed first-frame queries, no reset, no query replacement and default visibility. Frame 1 was initialization; all 174 subsequent frames remained in the denominator.

| Outcome | Result |
| --- | ---: |
| Visible and inside target mask, all opportunities | **457 / 1,392 (32.83%)** |
| Inside target mask, conditional on visible | **457 / 458 (99.78%)** |
| Marked not visible | 934 / 1,392 |
| Frames with no visible query | 77 / 174 |
| Visible outside-mask outputs | 1 |
| Whole watched CPU process | 83.80 s |
| Sampled owned-process RSS maximum | 731,660,288 bytes |
| Median prediction boundary | 0.4568 s |

The timing boundary includes feature extraction, tracking, coordinate conversion and scalar serialization, but excludes image decode and later checks. Sampled memory can miss short peaks. These measurements are not iPhone performance or steady-state FPS.

Independent saved-output arithmetic reproduced all 1,400 mask memberships, including initialization, the 1,392 evaluation classifications, coordinate ratios and visibility decisions. **Containment is not exact point tracking:** a prediction can slide inside the object's mask. A nonempty object mask does not prove a particular nominated point is visible. Therefore the 751 hidden-but-contained outputs cannot be labeled false occlusions. The already-seen clip, mask-assisted query selection and differing tasks also prevent a fair leaderboard against box IoU. [BootsTAPIR implementation](https://github.com/google-deepmind/tapnet)

The final source/metadata search found one smaller reference with actual per-point trajectories and occlusion labels: TAP-Vid RGB-Stacking, a publisher-described 50-video synthetic robotics set. Its complete ZIP advertises 187,291,581 bytes and the publisher assigns CC BY 4.0 to videos and annotations. No dataset body was acquired, so expansion, exact useful transitions and evaluation suitability remain uninspected. No complete comparably small real-video option was verified. This is a candidate for a later point-accuracy test, not a new result. [Publisher dataset documentation](https://github.com/google-deepmind/tapnet/tree/730cda1c730877cfedbe01bf87fb1cadb78a565d/tapnet/tapvid)

## Criteria, integration and transport

| Investigation | Established | Limit |
| --- | --- | --- |
| Placement intervals | Seven synthetic scenarios and 3,315 finite oracle comparisons exposed a coarse-grid miss | One-dimensional hard-bound assumptions; no calibrated physical uncertainty |
| Measurement interoperability | 30 paired synthetic CLI cases plus saved-output review | Units, equality, missing evidence and validator scopes; no image inspection or measurement-endpoint truth |
| One-wall handoff adapter | 23 methods / 30 calls, two parser controls and nine reply checks; 10 provisional and 20 withheld | Synthetic coordinate epochs and a separate measurement path, not production capture integration |
| Server pruning review | Actual source reproduced overly aggressive pruning; isolated correction tested; newer team source independently fixed the original default case | A remaining extreme-drift boundary was a stress case, not an observed household outcome. No whole-site/API accuracy result |
| Deployment observation | Official 4.5 MB Function envelope; three live GETs for health and schemas; served schema bytes matched inspected source | No deployed-code attestation, placement POST, media upload or reconstruction service |
| TUSKit upload work | Initial build exceeded its cap; a separate direct build produced client/library artifacts but exposed an SDK identity mismatch | A later explicitly scoped runtime attempt stopped at process-monitor permission denial **before** server, client or payload. No transfer ran |
| Apple segmentation | Actual model-interface inspection and prompt-harness controls completed | Prompt-only Core ML attempt stopped at a working-directory permission denial before model load/prediction. No mask-quality result |

Failed and denied attempts were preserved. No alternate permission path was used to bypass them. No paid GPU was provisioned. The user stop arrived before running the ground replay proposal, the prepared TUM depth diagnostic or any further research candidates.

## Publication and reproducibility

The checked-in [experiment packages](../../experiments/research-handoff/README.md) can be reviewed and tested independently. The native patches identify their precise public baseline and remain proposals. Raw local experiment trees retain frozen inputs, source/model identities, output records and reviews, but are not published here because they include third-party media, model files, build artifacts or private context.

The accompanying [evidence index](2026-09-26-evidence-index.json) records SHA-256 identities of selected locally retained reports and manifests. Those hashes identify the research snapshot; they are **not** a substitute for the unshipped evidence or an independently reproducible benchmark. The high-level [handoff](../06-research-handoff.md) gives the recommended next decisions and field test.
