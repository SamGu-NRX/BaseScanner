# Run heavy QA jobs

Use this queue for package builds and tests, Blender renders, and simulator runs. Run quick unit checks directly; they never need to wait for this queue. Python 3 on macOS is the only dependency.

From the worktree, submit a package job and wait for its result:

```sh
python3 tools/qa-resource/qa_resource.py submit --job-id package-001 --kind package --cwd "$PWD" --admission-deadline 1200 --timeout 600 -- swift test --package-path ios/HouseScanKit --jobs 1
python3 tools/qa-resource/qa_resource.py wait --job-id package-001 --max-wait 1800
python3 tools/qa-resource/qa_resource.py status --job-id package-001
python3 tools/qa-resource/qa_resource.py status
python3 tools/qa-resource/qa_resource.py cancel --job-id package-001
```

Use `run` instead of `submit` to stay in the foreground. Use `--kind render` for renders. For simulator work, use `--kind simulator --device UDID`; other kinds reject `--device`. Pick a new job id for every attempt. Existing job directories are never overwritten.

All subcommands accept `--state-dir DIR` and `--lock FILE`, before or after the subcommand. Defaults are `~/.codex/qa-resource` and the existing shared `~/.codex/local-ios-qa.lock`. Do not delete or replace the shared lock file.

Read `~/.codex/qa-resource/jobs/ID/job.json` for status, reasons, timestamps, ownership, and cleanup errors. `output.log` contains child output. `runner.log` contains timestamped runner events, also echoed by `run`. `submit` prints one JSON receipt with `jobId`, `jobDir`, `resultFile`, and runner `pid`. `wait` uses the job's kernel liveness lock, not polling. Its default maximum wait is 86400 seconds.

Nothing pushes a completion event to T3 or a manager session. A parent learns the result in one of two ways. It can block in `wait`, running it again with the same id if its shell tool's time limit is shorter than the job. Or it can start `run` as a background command and let its host report the exit. Either way, `job.json` holds the result.

Read `job.json`, not just the exit code. `run` and `wait` return the child's code for success or failure, 124 for child timeout, 130 for cancellation, 75 for admission timeout, and 125 for sensing or cleanup errors. `wait` returns 3 when its own deadline expires without affecting the job, 4 for a runner that died without a terminal result, and 2 for an unknown job. Child exit codes can overlap these values. If a child dies from signal N, `run` and `wait` return 128+N. `job.json` keeps the negative child return code in `exitCode` and N in `signal`.

Admission requires memory pressure level 1 or 2, at least 35% memory free, and at least 5 GiB free on the HOME volume. These are operational limits copied from `qa-slot.py`, not calibrated measurements. Unreadable resources fail admission. Heavy build and render processes block admission, except a verified agent-device `testCommand` service. That service blocks a simulator job only on the same device. The named simulator must exist and be Shutdown; other booted devices do not block. Package and render jobs never call `simctl`.

Heavy-process exit waits use kqueue. Memory recovery, disk space, and device state have no stdlib kernel notification here, so they are resampled every 30 seconds. The global lock stays held during resource waits. The admission deadline covers queueing and resource checks. Simulator boot and bootstatus each have a fixed 300-second limit, an operational limit rather than a measured startup time. Cancellation waits for the boot result and ownership record. If boot times out, the runner reports the device state but never shuts it down without proof of ownership. The child timeout starts separately.

## What the tool cannot guarantee

The queue cannot identify a foreign shared-lock holder or attribute a heavy process to a project. FIFO ordering applies only to this tool's tickets; `qa-slot.py` and `package-run.py` still race for the shared flock. Cancellation signals only a verified live runner, which stops its own child group and shuts down only the device it booted. The runner handles SIGTERM, SIGINT, and SIGHUP; later signals cannot interrupt cleanup. A stale job's recorded group and booted-device ownership are reported, never cleaned. Inspect those manually before reusing a device.

Cancel can signal a reused PID if reuse happens between the runner start-time check and SIGTERM; eliminating that window on macOS needs per-job IPC.

Boot ownership does not identify a simulator session; if another lane shuts down and re-boots the same UDID mid-job, final shutdown affects their session.

A stuck helper is killed at its subprocess timeout, but `subprocess.run` then reaps it without a deadline, so that failure can exceed the stated limits.

If group cleanup fails, the runner holds the shared lock for up to 300 more seconds, an operational limit rather than a measured recovery time. It releases the lock when no live members remain or the hold expires, records the outcome in `cleanupError`, and keeps status `cleanup_failed`.
