# Reusable prototypes from the live-survey research

These isolated experiments accompany the [research handoff](../../docs/06-research-handoff.md). They do not change the iOS app, server, web client or team-owned branches.

| Package | Purpose | State |
| --- | --- | --- |
| [capture-admission](capture-admission/README.md) | Credit progress only after the actual returned evidence is durably admitted under valid task/coordinate revisions | Executed synthetic prototype; see package test results |
| [equipment-association](equipment-association/README.md) | Keep observed labels, equipment candidates and reviewed associations distinct | Executed synthetic prototype; see package test results |
| [native-proposals](native-proposals/README.md) | Narrow stale-task fix and separate ground-coverage replay helper | Reset change tested in an isolated harness; ground helper prepared only; neither integrated |

Python packages use the standard library and temporary synthetic data. Their READMEs give exact commands and boundaries. Native patches target a pinned public source revision and are not automatically applied or built.

Downloaded weights/media, customer information, private criteria, build caches and local run receipts are intentionally excluded. Aggregate historical outcomes and failures remain visible in the [evidence report](../../docs/research/2026-09-26-experiment-evidence.md).
