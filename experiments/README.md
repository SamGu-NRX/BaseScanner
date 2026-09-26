# Experiments

An experiment answers one question the team needs settled before building on an assumption. For example: can an iPhone without LiDAR measure the gap between a wall and a fence to within a few inches?

- Give each experiment its own folder, `experiments/<short-name>/`.
- Its README states the question, the method and the pass criteria before the run, then the result and what it changes after. Keep the result when it fails; a failure tells us which part to change next.
- Keep dependencies inside the folder, in its own uv, pnpm or Xcode project. Don't add them to `server/`, `web/` or `ios/`.
- Write outputs to `data/`, which git ignores. Never commit photos, video or measurements of a real home, or Base's materials.
- Read and write the team's `scene.json` once it exists, so every method's numbers compare on the same terms.
