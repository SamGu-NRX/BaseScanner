# Research notes

Notes from the agents working beside the four lanes. They build on the team plan in [docs/00](../00-overview.md) through [docs/05](../05-live-guided-survey-hld.md). Each answers one question for one reader. They propose; the lane owners decide. `t3-` notes come from the Claude run and `codex-` notes from the Codex run.

| Note | Question it answers | For |
| --- | --- | --- |
| [t3-capture-surfaces.md](t3-capture-surfaces.md) | Which phone surface can measure what, and how does Android get covered later? | Everyone |
| [t3-no-lidar-capture.md](t3-no-lidar-capture.md) | How can an iPhone without LiDAR measure what the placement checks need, and how do we test that before relying on it? | Lanes A and B |
| [t3-first-try-capture.md](t3-first-try-capture.md) | How does the capture know it has enough before the homeowner leaves, and what does the homeowner see? | Lane A |
| [t3-lane-a-review.md](t3-lane-a-review.md) | What in the capture plan would fail on a real house on the first try? | Lane A |
| [t3-lane-c-review.md](t3-lane-c-review.md) | What must the solver settle before it can approve or reject a site, and which test cases prove it? | Lane C |
| [t3-scoring-protocol.md](t3-scoring-protocol.md) | How do we compare every capture method fairly on one to three houses, and what can we claim? | Lane D |

Base's own criteria never appear here: thresholds without a public source are named `rules.yaml` parameters.
