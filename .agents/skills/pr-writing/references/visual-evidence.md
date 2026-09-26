# Visual evidence

Choose the changed behavior before collecting media. Capture the actual route or component through the host's supported browser, simulator or desktop tools. Do not redraw an interface to stand in for a screenshot. A design prototype is evidence of that prototype, not of the native or deployed product.

## Capture a fair comparison

Record the before and after revisions. Use the same viewport or device, route, data and relevant state. For a bug, reproduce the triggering condition on both versions. For a new feature, show the new flow and identify it as new. If the old build cannot run, label the missing or historical reference rather than fabricating a baseline.

Use isolated worktrees or existing builds so capturing the base does not disturb the active writer. Use approved test data. Identify fixture-driven behavior where it limits the claim; a visible success state does not prove a live backend write. Keep the capture procedure in the repository when it is reusable, including the route, fixture and build commands that actually worked.

Place Before and After adjacent at readable, matching sizes. Label them and caption the behavioral difference. Crop to the relevant area consistently without hiding context needed to judge the change. Avoid tall comparison boards with large blank gaps or a gallery of unchanged screens. Preserve original captures when preparing a comparison.

Record motion at normal speed with the trigger, transition and settled result visible. Trim idle time without hiding failures or changing the timing being evaluated. Use H.264 MP4 when compatible with the host. Watch the encoded recording for dropped frames, legible text and correct orientation before uploading it.

## Publish and verify

Use GitHub repository attachments for inline evidence, especially in private repositories. Keep sensitive captures off anonymous public image hosts. A private raw-file URL or a local filesystem path is not a reliable inline attachment.

Prefer the installed GitHub CLI's documented attachment support when available; check command help before relying on `--attach`. Otherwise use the authenticated GitHub attachment UI or a repository's verified uploader. Do not copy an app-specific authentication workaround into another project. For a local before/after composition tool, verify its output mode before running it so capture files are not uploaded elsewhere.

With CLI attachment support, reference the local files in the Markdown body and pass each file with `--attach` alongside `--body-file`. The CLI replaces those references with uploaded URLs. If an upload partially fails, inspect the returned PR and its body before retrying: creation can succeed even when the command exits nonzero. Repair the existing PR rather than creating another.

Use a compact Markdown table for a pair. Give images descriptive alt text. Put an interaction video in its own paragraph so it can render as a player. Preserve the original attachment URLs when editing an existing body.

Reopen the PR in its actual rendered view. Check that both images load at useful sizes, labels match their revisions, and the video plays. If publication or viewing is unavailable, return the draft and evidence paths with that specific remaining step.

GitHub documents [attachment access and supported formats](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files) and [CLI attachment support](https://docs.github.com/en/github-cli/github-cli/attaching-files-with-github-cli).
