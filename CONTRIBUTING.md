# Contributing

## Branches and worktrees

Branch from `main` and open a pull request; nobody pushes to `main` directly. One person or agent writes to a branch at a time. Parallel work uses separate worktrees:

```sh
git worktree add ../house-scanning-<topic> -b <name>/<topic> origin/main
```

Clone with the landing page submodule, or fetch it later with `git submodule update --init sites/landing`.

## This repository is public

Never commit photos, video, scans or measurements of a real home, street addresses, meter or account numbers, or the materials Base gave the team. Base's materials stay in `private/`, real captures in `captures/` or `fixtures/real/`, and experiment outputs in `data/`. Git ignores all four. Test fixtures are synthetic.

## Pull requests

Keep a pull request focused. A larger change is fine when its parts belong together.

State what the old code did before describing the new behavior. Link the reviewed files where that helps. Show only changed UI behavior, list known gaps, and report commands that actually ran with their results.

The `size:*` label describes the effective diff. It is a review signal, not a merge gate. Do not set it by hand.

## Checks

| Check | Runs on GitHub when | Local command |
| --- | --- | --- |
| Server checks | `server/` changes | `make server` |
| Web checks | `web/` changes | `make web` |
| iOS build | `ios/` changes outside Markdown, on non-draft pull requests | `make ios` |
| Sync label definitions | `.github/labels.json` changes on `main` | none |
| Label PR size | a pull request opens or updates | none |

The iOS UI tests skip the every-state accessibility audit on pull requests, because it adds about 10 minutes and macOS runners are scarce. Add the `full-ui` label when a pull request changes screens or copy; pushes to `t3/ios-mvf` and `main` always run it.

`make check` runs the three local suites. They need uv, Node 24 with pnpm, and Xcode 26 or newer; each directory's README has details. No check is required by branch rules yet. Don't call one required until the rules require its status.

Keep workflows that run pull-request code away from production credentials and destructive external systems. A green CI run is evidence for the checks it ran, not proof that a capture works on a real house.
