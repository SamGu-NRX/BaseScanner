# Experiments

An experiment settles one question before the team builds on the answer. For example: can an iPhone without LiDAR measure the gap between a wall and a fence to within a few inches?

The [research handoff packages](research-handoff/README.md) contain reusable capture/evidence prototypes and isolated native proposals from the September 26 investigation. Start with the [high-level report](../docs/06-research-handoff.md) for their results and limitations.

The record of an experiment is its code and the files it produced. Its README is the front door, not the report.

- One folder per experiment, `experiments/<short-name>/`, with its own uv, pnpm or Xcode project. Its dependencies stay out of `server/`, `ios/` and `web/`.
- The README stays under about 200 words: the question and its pass criteria, written before the run, the command that runs it and what that needs, the result in a sentence or two with its numbers, and what it changed in the product or the plan. Keep a failed result, because it says which part to change next.
- Generated tables and plots from public data go in `results/` inside the folder, with the command that produced them. Anything from a real home, and anything Base gave us, goes in git-ignored `data/`.
- When the product or the plan relies on the result, `docs/00-overview.md` gets one line under "Evidence so far" that points here.
- Delete an experiment when a later one supersedes it. First point its line in `docs/00` at the experiment that replaced it, so the finding stays and its source still exists. Git keeps the old code.
- Read and write `scene.json`, the app's measurement file, so every method's numbers compare on the same terms.
