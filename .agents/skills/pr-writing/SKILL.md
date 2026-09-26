---
name: pr-writing
description: Write or revise pull request titles, descriptions and visual evidence. Use when preparing a PR, improving its presentation, or updating it after scope changes. Writing alone does not publish the PR.
---

# Write a reviewable PR

Read the repository's template and contributor guidance, the diff against the actual PR base, and the current PR body before drafting. Apply `unslop` and `technical-writing` when installed. Preserve useful human edits, existing evidence links and bot-managed sections. Refresh the body before publishing an edit so another author's changes are not overwritten.

## Explain the change

Lead with the concrete problem and resulting behavior. Name the affected screen, operation or interface so someone outside the task can understand it. For a substantial change, explain the old behavior, its consequence, and how the change fixes it. For a new feature, describe the new capability without inventing a broken predecessor.

Order independent changes by user impact or technical consequence. Headings identify the change; filenames and commit order are not the outline. Explain the mechanism where it helps assess correctness or a tradeoff. Link the relevant diff when available, otherwise the file at the reviewed revision. Include prior research only when it supports a consequential choice, with a direct source and the reason it matters.

Write connected prose with concrete subjects and verbs. Avoid clipped status phrases, unexplained internal names, claims of thoroughness and narration about the reviewer or your process. Keep useful technical detail; remove sentences that add no decision-relevant information. Read the short [writing examples](references/writing-examples.md) before drafting. Follow their level of explanation, not their sentence pattern or length.

Scale the body to the change. A small repair needs a short explanation and focused verification. A broad PR can use sections by behavior with evidence beside each claim. Keep long logs, inventories and test matrices in linked artifacts. Do not copy a task transcript, delegate report or commit diary into the description.

## Present evidence

For visible changes, read [visual evidence](references/visual-evidence.md) and include matched before/after captures from the running app. Add a short recording when motion, timing or interaction is the change. Show only affected behavior. A new screen can have an after-only capture; say it is new. Missing evidence stays a stated gap.

Report checks actually run and their results, with commands or durable run links. State material limits next to the claims they qualify: fixtures, simulator-only behavior, a failed or skipped check, or an untested service. Keep reproduction steps separate from completed verification. Green CI does not establish visual quality or product acceptance.

## Use the repository template

The repository's template, `.github/pull_request_template.md`, starts with What changed, Why, UI changes and four checklist items. Keep existing repository requirements. Add verification and risk where useful; remove empty optional sections and avoid repeating the same explanation under two headings. Replace inapplicable checklist items with a plain `N/A` note; check only completed work. Large cohesive changes are valid; do not call them small to satisfy a checkbox.

Write the title around the final change, using the repository's title convention. In stacked work, name the immediate base and necessary dependencies, and describe this PR's own contribution. When scope changes, update the title, body and affected evidence together. Keep still-valid captures with their revision labels instead of implying they show a newer build.

Use a body file or structured tool argument when publishing. Reopen the saved PR to check its text, links, comparison layout and video playback. A local draft or successful upload alone does not establish that the published body renders correctly. Creating the PR, pushing and handling reviews are separate steps, each within the user's authorization.
