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

`cancel` never signals a PID. Each runner reads a per-job FIFO, `cancel.fifo` in the job directory, and cancels itself when a byte arrives. The command that creates the job opens the read end before the runner starts and hands it to the runner, so a cancel sent during runner startup waits in the pipe and takes effect once the runner listens. When neither holds the read end, `cancel` cannot open the FIFO, reports that nothing was sent, and returns 4, so a reused runner PID can never receive the request. Jobs started by an older runner have no FIFO, and `cancel` refuses them. If `submit` is interrupted after starting the runner, it cancels that runner, which is still its own unreaped child, and prints the receipt with `cancelRequested: true` before returning 130, so `wait` can follow the job to `cancelled`. If the interruption arrives while the receipt is being written, stdout was blocked, usually by a pipe nobody reads. `submit` then still cancels the runner and returns 130, but prints no second receipt, because writing again would block again and leave it unstoppable. The caller supplied the job ID, so `wait ID` and `job.json` still report the outcome.

Read `job.json`, not just the exit code. `run` and `wait` return the child's code for success or failure, 124 for child timeout, 130 for cancellation, 75 for admission timeout, and 125 for sensing or cleanup errors. `wait` returns 3 when its own deadline expires without affecting the job, 4 for a runner that died without a terminal result, and 2 for an unknown job. Child exit codes can overlap these values. If a child dies from signal N, `run` and `wait` return 128+N. `job.json` keeps the negative child return code in `exitCode` and N in `signal`.

Admission requires memory pressure level 1 or 2, at least 35% memory free, and at least 5 GiB free on the HOME volume. These are operational limits copied from `qa-slot.py`, not calibrated measurements. Unreadable resources fail admission. Heavy build and render processes block admission, except a verified agent-device `testCommand` service, meaning an `xcodebuild test-without-building` with no other action whose every `-only-testing` selector names `testCommand`. That service blocks a simulator job unless every one of its `-destination` values names a different device by `id=`, because a name, an OS or an implicit destination may resolve to the job's device. The named simulator must exist and be Shutdown; other booted devices do not block. Package and render jobs never call `simctl`.

Heavy-process exit waits use kqueue. Memory recovery, disk space, and device state have no stdlib kernel notification here, so they are resampled every 30 seconds. The global lock stays held during resource waits. The admission deadline covers queueing and resource checks. Simulator boot and bootstatus each have a fixed 300-second limit, an operational limit rather than a measured startup time. Cancellation waits for the boot result and ownership record. If boot times out, the runner reports the device state but never shuts it down without proof of ownership. The child timeout starts separately.

## Inside a machine-wide command lock

Some machines also make every heavy command take an outer lock, such as `/usr/bin/lockf -k <lock> <command>`. Take that lock first and run the queue's `run` inside it:

```sh
/usr/bin/lockf -k <lock> python3 tools/qa-resource/qa_resource.py run --job-id JOB --kind package --cwd "$PWD" --admission-deadline 1800 --timeout 3600 -- <command>
```

`lockf` holds its lock only until its own command exits. `run` stays in the foreground until cleanup ends, so both locks cover the whole job. `submit` returns as soon as the detached runner starts, so under `lockf` the job runs without the outer lock. Don't put `lockf` inside the queue (`... -- lockf <lock> <command>`) either. That reverses the lock order, so a job waits on another lane that holds the outer lock while it waits for the queue. A simulator job would also boot its device before it holds the outer lock. Cancel with `cancel --job-id`, not by killing `lockf`.

## Escaped descendants

Each payload gets a random `QA_RESOURCE_OWNER_<token>=<jobId>` environment entry. At admission and cleanup, the runner reads process memory with Darwin `KERN_PROCARGS2`. An exact entry or live-parent ancestry proves ownership at discovery. The parser checks every NUL-separated string after the executable because empty `argv[0]` is indistinguishable from padding. Admission accepts only owner headers with a 32-character lowercase hexadecimal token.

On cancellation, timeout, and normal exit, the runner signals discovered escapes before its pinned child group. Discovery proof stays attached to PID, microsecond start time, and uid even after reparenting or token removal. Each per-PID signal rechecks that identity with `KERN_PROC_PID` and excludes zombies and other uids. The runner never signals an escaped process's new group. The leader stays unreaped until checks finish.

`escapedProcesses` in `job.json` and `runner.log` records `pid`, `start_us`, `uid`, human-readable `start`, executable at discovery, proof, and outcome. `terminated` and `killed` mean the runner sent that signal and then confirmed the identity was no longer live. `exited` means no signal was sent; `retained` means cleanup could not confirm exit.

Confirmation requires two consecutive complete empty passes at least 0.1 seconds apart, after the last observed owned process. Incomplete reads or expired inspection budgets never count as empty. Discovery errors do not skip signaling the pinned group, but the job reports `cleanup_failed` and enters the cleanup hold.

Admission waits for live same-user owner entries, including orphans from dead runners or expired holds. It never signals these blockers. The runner and its ancestors are excluded as a defense. The payload does not inherit the global lock descriptor. `run` and `submit` reject an inherited owner entry before creating a job, returning 2 with `nested qa-resource jobs are not supported: this process belongs to job X`.

## What the tool cannot guarantee

The token is a cooperative marker in mutable process memory, not an authenticated exec record. A process can overwrite its environment strings, exec without the token, or copy the token. Copying it onto an unrelated same-uid process makes cleanup treat that process as owned and signal it.

Invisible descendants are not stopped. Darwin omits the environment of `cs_restricted` processes without an error, other-uid environments are unreadable, and already-reparented tokenless helpers have no ancestry after natural exit. An unreadable environment without ancestry is not ownership proof. A descendant under another uid cannot be signaled; if ancestry finds it, cleanup fails. `succeeded` means no observable owned process remained, not that every descendant was stopped.

A chain whose processes each live shorter than one scan interval can evade two-pass confirmation. Microsecond start times avoid coarse `lstart` identity checks for escaped PIDs, but the check-to-signal PID reuse window remains.

The queue cannot identify a foreign shared-lock holder or attribute a heavy process to a project. FIFO ordering applies only to this tool's tickets; `qa-slot.py` and `package-run.py` still race for the shared flock. Cancellation stops only the job's own child group and proven escaped descendants, and shuts down only the device the job booted. The runner handles SIGTERM, SIGINT, and SIGHUP; later signals cannot interrupt cleanup. A stale job's recorded group and booted-device ownership are reported, never cleaned. Inspect those manually before reusing a device.


Boot ownership does not identify a simulator session; if another lane shuts down and re-boots the same UDID mid-job, final shutdown affects their session.

A stuck helper is killed at its subprocess timeout, but `subprocess.run` then reaps it without a deadline, so that failure can exceed the stated limits.

If group or escaped-process cleanup fails, the runner holds the shared lock for up to 300 more seconds, an operational limit rather than a measured recovery time. It releases the lock after two complete empty passes or when the hold expires, records retained PID identities and the hold outcome in `cleanupError`, and keeps status `cleanup_failed`. Same-user token-bearing survivors still block later admission.
