#!/usr/bin/env python3
"""Serialize heavyweight local QA work without taking ownership of other jobs."""
import argparse
from contextlib import closing, contextmanager
from datetime import datetime, timezone
import errno
import fcntl
import json
import math
import os
from pathlib import Path
import re
import select
import shlex
import signal
import subprocess
import sys
import time

# Operational limits copied from qa-slot.py, not calibrated measurements.
MIN_MEMORY_PERCENT = 35
MIN_DISK_BYTES = 5 * 1024**3
ALLOWED_PRESSURES = (1, 2)
RESAMPLE_SECONDS = 30
CLEANUP_GRACE_SECONDS = 10
CLEANUP_CONFIRM_SECONDS = 3
# Operational hold limit, not a measured time for an unkillable process to exit.
CLEANUP_HOLD_SECONDS = 300
SENSING_TIMEOUT = 10
# Operational boot limit, not a measured simulator startup time.
BOOT_TIMEOUT_SECONDS = 300
RUNNER_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
HEAVY_NAMES = {"xcodebuild", "swift-build", "swift-test", "swift-frontend",
               "swift-driver", "blender"}
SERVICE_TEST = "AgentDeviceRunnerUITests/RunnerTests/testCommand"
TERMINAL = {"succeeded", "failed", "timed_out", "cancelled", "admission_timeout",
            "error", "cleanup_failed"}


class Cancelled(Exception):
    def __init__(self, signum):
        self.signum = signum


class DeadlineExpired(Exception):
    pass


def timestamp():
    return datetime.now(timezone.utc).isoformat()


@contextmanager
def bounded(seconds):
    """Interrupt even a blocking flock; Python retries EINTR unless handlers raise."""
    if seconds <= 0:
        raise DeadlineExpired()
    old = signal.getsignal(signal.SIGALRM)
    def alarm(signum, frame):
        raise DeadlineExpired()
    signal.signal(signal.SIGALRM, alarm)
    previous = signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, old)
        if previous[0]:
            signal.setitimer(signal.ITIMER_REAL, *previous)


def command_output(argv):
    # subprocess.run kills a timed-out helper, but its subsequent reap is unbounded.
    result = subprocess.run(argv, capture_output=True, text=True, timeout=SENSING_TIMEOUT)
    if result.returncode:
        raise RuntimeError(f"{' '.join(argv)} exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout.strip()


def runner_start(pid):
    return command_output(["ps", "-o", "lstart=", "-p", str(pid)])


def sense_memory():
    try:
        pressure = int(command_output(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]))
        text = command_output(["memory_pressure"])
        match = re.search(r"System-wide memory free percentage: (\d+)%", text)
        if not match or not 0 <= int(match[1]) <= 100:
            raise ValueError("missing or invalid free percentage")
        return pressure, int(match[1])
    except (Cancelled, DeadlineExpired):
        raise
    except Exception as error:
        raise RuntimeError(f"cannot read memory: {error}") from error


def sense_disk():
    # df uses the HOME volume and lets subprocess tests substitute the executable.
    text = command_output(["df", "-Pk", str(Path.home())])
    match = re.search(r"^.+?\s+\d+\s+\d+\s+(\d+)\s+\d+%\s+", text.splitlines()[-1]) if text else None
    if match is None:
        raise RuntimeError(f"cannot read free disk bytes: {text!r}")
    return int(match[1]) * 1024


def list_processes():
    rows = command_output(["ps", "-axo", "pid=,pgid=,stat=,comm="])
    processes = []
    for row in rows.splitlines():
        pid, pgid, state, comm = row.strip().split(maxsplit=3)
        if int(pid) == os.getpid() or state.startswith("Z") or Path(comm).name not in HEAVY_NAMES:
            continue
        # comm may contain spaces. Only the first three columns are split.
        # A timed-out ps is killed, but subprocess.run's subsequent reap is unbounded.
        args = subprocess.run(["ps", "-o", "args=", "-p", pid], capture_output=True,
                              text=True, timeout=SENSING_TIMEOUT)
        if args.returncode:  # The process may have exited between the two ps calls.
            if args.returncode == 1 and not args.stdout.strip():
                continue
            raise RuntimeError(f"cannot inspect arguments for process {pid}")
        processes.append(dict(pid=int(pid), pgid=int(pgid), stat=state,
                              comm=comm, args=args.stdout.strip()))
    return processes


def option_values(tokens, option):
    values = []
    for index, token in enumerate(tokens):
        if token == option and index + 1 < len(tokens):
            values.append(tokens[index + 1])
        elif token.startswith(option + ":"):
            values.append(token[len(option) + 1:])
    return values


def classify_process(process, kind, device=None):
    """Return blocker, ignored, or irrelevant without inspecting the machine."""
    if process.get("stat", "").startswith("Z") or Path(process["comm"]).name not in HEAVY_NAMES:
        return "irrelevant"
    try:
        tokens = shlex.split(process["args"])
    except ValueError:
        return "blocker"
    service = (Path(process["comm"]).name == "xcodebuild"
               and "test-without-building" in tokens
               and SERVICE_TEST in option_values(tokens, "-only-testing"))
    if not service:
        return "blocker"
    destinations = []
    for index, token in enumerate(tokens):
        if token == "-destination":
            # ps args does not preserve argv quoting around 'iOS Simulator'.
            # Join the value through the next option to retain its comma-delimited id.
            end = index + 1
            while end < len(tokens) and not tokens[end].startswith("-"):
                end += 1
            destinations.append(" ".join(tokens[index + 1:end]))
    matches = any(re.search(r"(?:^|,)\s*id=" + re.escape(device or "") + r"(?:,|$)", d)
                  for d in destinations)
    return "blocker" if kind == "simulator" and matches else "ignored"


def resource_blockers(pressure, memory_percent, free_bytes):
    reasons = []
    if pressure not in ALLOWED_PRESSURES or memory_percent < MIN_MEMORY_PERCENT:
        reasons.append(f"memory pressure {pressure}, {memory_percent}% free")
    if free_bytes < MIN_DISK_BYTES:
        reasons.append("less than 5 GiB free on HOME volume")
    return reasons


def simctl(*args, timeout=SENSING_TIMEOUT):
    # A timeout kills xcrun, but subprocess.run does not bound the subsequent reap.
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True,
                          text=True, timeout=timeout)


def sense_devices():
    result = simctl("list", "devices", "-j")
    if result.returncode:
        raise RuntimeError(f"xcrun simctl list devices -j exited {result.returncode}")
    try:
        return [device for group in json.loads(result.stdout)["devices"].values() for device in group]
    except (ValueError, KeyError, TypeError) as error:
        raise RuntimeError("cannot parse xcrun simctl list devices -j") from error


def wait_process_exit(pids, seconds):
    with closing(select.kqueue()) as queue:
        registered = False
        for pid in pids:
            try:
                queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                             flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                             fflags=select.KQ_NOTE_EXIT)], 0, 0)
                registered = True
            except OSError as error:
                if error.errno != errno.ESRCH:
                    raise
                return  # Resample immediately if a blocker has already exited.
        if registered:
            queue.control(None, len(pids), seconds)


def group_has_members(pgid):
    rows = command_output(["ps", "-axo", "pgid=,stat="])
    return any(int(group) == pgid and not state.startswith("Z")
               for group, state in (row.split() for row in rows.splitlines()))


def signal_owned_group(pgid, signum):
    try:
        os.killpg(pgid, signum)
        return True
    except ProcessLookupError:
        return False
    except PermissionError as error:
        # Darwin can return EPERM for zombies. Inspect before declaring release.
        if not group_has_members(pgid):
            return False
        raise RuntimeError(f"cannot signal owned group {pgid}; live members remain") from error


def wait_child_exit(child, seconds):
    """Observe exit without reaping; the zombie leader pins its process-group id."""
    with closing(select.kqueue()) as queue:
        event = select.kevent(child.pid, filter=select.KQ_FILTER_PROC,
                              flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                              fflags=select.KQ_NOTE_EXIT)
        try:
            return bool(queue.control([event], 1, max(0, seconds)))
        except OSError as error:
            if error.errno != errno.ESRCH:
                raise
            # This is our direct, unreaped child, so ESRCH means it already exited.
            return True


def stop_owned_command(child):
    if child is None:
        return None
    # Never poll or reap before the last group operation: the leader pins the pgid.
    if signal_owned_group(child.pid, signal.SIGTERM):
        deadline = time.monotonic() + CLEANUP_GRACE_SECONDS
        while time.monotonic() < deadline:
            if not group_has_members(child.pid):
                break
            time.sleep(0.05)
        else:
            signal_owned_group(child.pid, signal.SIGKILL)
    deadline = time.monotonic() + CLEANUP_CONFIRM_SECONDS
    while group_has_members(child.pid):
        if time.monotonic() >= deadline:
            raise RuntimeError(f"could not confirm owned group {child.pid} gone")
        time.sleep(0.05)
    return child.wait(timeout=CLEANUP_CONFIRM_SECONDS)


def hold_owned_group(child):
    deadline = time.monotonic() + CLEANUP_HOLD_SECONDS
    while True:
        try:
            if not group_has_members(child.pid):
                return "no live members remained when the shared QA lock was released"
            remaining = "live members remained"
        except Exception as error:
            remaining = f"live membership was unknown ({error})"
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            return f"{remaining} when the shared QA lock was released after the cleanup hold expired"
        time.sleep(min(1, seconds))


def cleanup_step(errors, label, action):
    try:
        action()
    except Exception as error:
        errors.append(f"{label}: {error}")


@contextmanager
def deferred_signals(signals):
    pending = []
    def record(signum, frame):
        if not pending:
            pending.append(signum)
    previous = {sig: signal.signal(sig, record) for sig in signals}
    try:
        yield pending
    finally:
        errors = []
        for sig, handler in previous.items():
            try:
                signal.signal(sig, handler)
            except Cancelled as error:
                if not pending:
                    pending.append(error.signum)
            except Exception as error:
                errors.append(f"restore signal {sig}: {error}")
        if errors:
            raise RuntimeError("; ".join(errors))


def write_job(directory, job):
    temporary = directory / "job.json.tmp"
    temporary.write_text(json.dumps(job, sort_keys=True) + "\n")
    os.replace(temporary, directory / "job.json")


def read_job(directory):
    return json.loads((directory / "job.json").read_text())


def exit_code(job):
    child_code = job["exitCode"] or 0
    if child_code < 0:
        child_code = 128 - child_code
    return {"timed_out": 124, "cancelled": 130, "admission_timeout": 75,
            "error": 125, "cleanup_failed": 125}.get(job["status"], child_code)


def create_job(args):
    directory = args.state_dir / "jobs" / args.job_id
    directory.parent.mkdir(parents=True, exist_ok=True)
    try:
        directory.mkdir()
    except FileExistsError as error:
        raise ValueError(f"job {args.job_id} already exists; choose a new id") from error
    live = (directory / "live.lock").open("a+")
    fcntl.flock(live, fcntl.LOCK_EX | fcntl.LOCK_NB)
    job = dict(jobId=args.job_id, kind=args.kind, argv=args.argv, cwd=str(args.cwd),
               device=args.device, status="queued", reasons=[], runnerPid=None,
               runnerStart=None, childPgid=None, bootedByJob=False, exitCode=None,
               signal=None, error=None, shutdownExitCode=None, cleanupError=None,
               queuedAt=timestamp(), admittedAt=None, finishedAt=None,
               admissionDeadline=args.admission_deadline, timeout=args.timeout,
               ignoredProcesses=[], logs={name: str(directory / (name + ".log"))
                                         for name in ("output", "runner")})
    (directory / "output.log").touch()
    (directory / "runner.log").touch()
    write_job(directory, job)
    return directory, live, job


def acquire_ticket(state_dir, job_id, deadline):
    queue = state_dir / "queue"
    queue.mkdir(parents=True, exist_ok=True)
    with (queue / ".guard").open("a+") as guard:
        with bounded(deadline - time.monotonic()):
            fcntl.flock(guard, fcntl.LOCK_EX)
        counter = queue / "counter"
        seq = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(seq))
        path = queue / f"{seq:012d}.{job_id}"
        ticket = path.open("a+")
        fcntl.flock(ticket, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return path, ticket


def release_ticket(path, ticket):
    errors = []
    # Unlink while locked so the next head cannot mistake us for a live ticket.
    if path is not None:
        cleanup_step(errors, "unlink queue ticket", lambda: path.unlink(missing_ok=True))
    if ticket is not None and not ticket.closed:
        cleanup_step(errors, "unlock queue ticket", lambda: fcntl.flock(ticket, fcntl.LOCK_UN))
        cleanup_step(errors, "close queue ticket", ticket.close)
    return errors


def run_job(directory, live, job, lock_path, echo=True, owned_ticket=None, deadline=None):
    global_lock = child = None
    child_finished = False
    cleanup_errors = []
    ticket_path, ticket = owned_ticket if owned_ticket else (None, None)
    if deadline is None:
        deadline = time.monotonic() + job["admissionDeadline"]
    log = (directory / "runner.log").open("a", buffering=1)
    def update(**fields):
        job.update(fields)
        write_job(directory, job)
        line = f"{timestamp()} {job['status']} " + json.dumps(fields, sort_keys=True)
        log.write(line + "\n")
        if echo:
            print(line, flush=True)
    def interrupted(signum, frame):
        # A second signal must not escape while the first exception is handled.
        for sig in RUNNER_SIGNALS:
            signal.signal(sig, signal.SIG_IGN)
        raise Cancelled(signum)
    old_signals = {sig: signal.signal(sig, interrupted) for sig in RUNNER_SIGNALS}
    try:
        update(runnerPid=os.getpid(), runnerStart=runner_start(os.getpid()))
        if ticket is None:
            ticket_path, ticket = acquire_ticket(directory.parent.parent, job["jobId"], deadline)
        while True:
            lower = sorted(p for p in ticket_path.parent.iterdir()
                           if re.match(r"\d{12}\.", p.name) and p.name < ticket_path.name)
            if not lower:
                break
            update(status="waiting", reasons=[f"queued behind {lower[-1].name}"])
            try:
                prior = lower[-1].open("r")
            except FileNotFoundError:
                continue
            with prior, bounded(deadline - time.monotonic()):
                fcntl.flock(prior, fcntl.LOCK_SH)
                lower[-1].unlink(missing_ok=True)
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        # This inode is shared with existing tools. Never unlink or replace it.
        global_lock = lock_path.open("a+")
        try:
            fcntl.flock(global_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            update(status="waiting", reasons=["shared QA lock held by another holder"])
            with bounded(deadline - time.monotonic()):
                fcntl.flock(global_lock, fcntl.LOCK_EX)
        cleanup_errors.extend(release_ticket(ticket_path, ticket))
        while True:
            with bounded(deadline - time.monotonic()):
                pressure, memory = sense_memory()
                reasons = resource_blockers(pressure, memory, sense_disk())
                heavy, ignored = [], []
                for process in list_processes():
                    classification = classify_process(process, job["kind"], job["device"])
                    if classification == "blocker":
                        heavy.append(process["pid"])
                        reasons.append(f"heavy process {process['pid']} {process['comm']}")
                    elif classification == "ignored":
                        ignored.append(dict(pid=process["pid"], reason="verified agent-device service on another or unneeded device"))
                if job["kind"] == "simulator":
                    devices = sense_devices()
                    target = next((d for d in devices if d["udid"] == job["device"]), None)
                    if target is None:
                        raise RuntimeError(f"device {job['device']} does not exist; no device is created")
                    # Other booted devices do not block; memory limits cover their load.
                    if target["state"] != "Shutdown":
                        reasons.append(f"device {job['device']} is {target['state']}")
                update(status="waiting", reasons=reasons, ignoredProcesses=ignored)
            if not reasons:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DeadlineExpired()
            if heavy:
                wait_process_exit(heavy, min(remaining, RESAMPLE_SECONDS))
            else:
                time.sleep(min(remaining, RESAMPLE_SECONDS))
        if job["kind"] == "simulator":
            # CoreSimulator can finish a boot after xcrun is interrupted. Defer
            # cancellation until success and its ownership record are both known.
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, RUNNER_SIGNALS)
            try:
                try:
                    result = simctl("boot", job["device"], timeout=BOOT_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired as error:
                    try:
                        devices = sense_devices()
                        target = next((d for d in devices if d["udid"] == job["device"]), None)
                        state = f"device is {target['state']}" if target else "device is missing"
                    except Exception as inspection_error:
                        state = f"device state unreadable: {inspection_error}"
                    raise RuntimeError(
                        f"boot of {job['device']} did not finish in {BOOT_TIMEOUT_SECONDS:g} s; "
                        f"{state}; not shut down because this job cannot prove it booted it"
                    ) from error
                if result.returncode:
                    raise RuntimeError(f"xcrun simctl boot {job['device']} exited {result.returncode}")
                update(bootedByJob=True)
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            try:
                result = simctl("bootstatus", job["device"], timeout=BOOT_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired as error:
                raise RuntimeError(
                    f"xcrun simctl bootstatus {job['device']} did not finish in {BOOT_TIMEOUT_SECONDS:g} s"
                ) from error
            if result.returncode:
                raise RuntimeError(f"xcrun simctl bootstatus {job['device']} exited {result.returncode}")
        elif time.monotonic() >= deadline:
            raise DeadlineExpired()
        with (directory / "output.log").open("a") as output:
            # Record cancellation without blocking signals inherited by the payload.
            with deferred_signals(RUNNER_SIGNALS) as pending:
                child = subprocess.Popen(job["argv"], cwd=job["cwd"], start_new_session=True,
                                         stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT)
                child_started = time.monotonic()
                job["childPgid"] = child.pid
                write_job(directory, job)
            if pending:
                interrupted(pending[0], None)
        update(status="running", reasons=[], admittedAt=timestamp(), childPgid=child.pid)
        child_finished = wait_child_exit(child, job["timeout"] - (time.monotonic() - child_started))
        if not child_finished:
            job.update(status="timed_out", exitCode=124)
    except Cancelled as error:
        job.update(status="cancelled", exitCode=130, signal=error.signum)
    except DeadlineExpired:
        job.update(status="admission_timeout", exitCode=75)
    except Exception as error:
        if isinstance(error, subprocess.TimeoutExpired) and time.monotonic() >= deadline:
            job.update(status="admission_timeout", exitCode=75)
        else:
            job.update(status="error", exitCode=125, error=str(error))
    finally:
        def mark_cleanup_errors():
            if cleanup_errors:
                job.update(status="cleanup_failed", exitCode=125, cleanupError="; ".join(cleanup_errors))
        for sig in old_signals:
            cleanup_step(cleanup_errors, f"ignore signal {sig}", lambda sig=sig: signal.signal(sig, signal.SIG_IGN))
        try:
            code = stop_owned_command(child)
            if child_finished and job["status"] == "running":
                job.update(status="succeeded" if code == 0 else "failed", exitCode=code,
                           signal=-code if code < 0 else None)
        except Exception as error:
            cleanup_errors.append(f"stop owned group: {error}")
            mark_cleanup_errors()
            cleanup_step(cleanup_errors, "write cleanup hold status", lambda: write_job(directory, job))
            if child is not None:
                try:
                    cleanup_errors.append(hold_owned_group(child))
                except Exception as hold_error:
                    cleanup_errors.append(f"cleanup hold: {hold_error}; live membership unknown at lock release")
                # All group signaling and inspection are over before this reap.
                cleanup_step(cleanup_errors, "reap owned child after hold",
                             lambda: child.wait(timeout=CLEANUP_CONFIRM_SECONDS))
        if job["bootedByJob"]:
            try:
                # Ownership proves boot success, not session identity after another lane reboots this UDID.
                result = simctl("shutdown", job["device"])
                job["shutdownExitCode"] = result.returncode
                if result.returncode:
                    raise RuntimeError(f"xcrun simctl shutdown {job['device']} exited {result.returncode}")
            except Exception as error:
                cleanup_errors.append(str(error))
        mark_cleanup_errors()
        cleanup_step(cleanup_errors, "write terminal result", lambda: update(finishedAt=timestamp()))
        if global_lock is not None:
            cleanup_step(cleanup_errors, "unlock shared QA lock", lambda: fcntl.flock(global_lock, fcntl.LOCK_UN))
            cleanup_step(cleanup_errors, "close shared QA lock", global_lock.close)
        cleanup_step(cleanup_errors, "release queue ticket",
                     lambda: cleanup_errors.extend(release_ticket(ticket_path, ticket)))
        cleanup_step(cleanup_errors, "close runner log", log.close)
        mark_cleanup_errors()
        cleanup_step(cleanup_errors, "write release result", lambda: write_job(directory, job))
        recorded_errors = len(cleanup_errors)
        cleanup_step(cleanup_errors, "close liveness lock", live.close)
        for sig, previous in old_signals.items():
            cleanup_step(cleanup_errors, f"restore signal {sig}",
                         lambda sig=sig, previous=previous: signal.signal(sig, previous))
        if len(cleanup_errors) != recorded_errors:
            mark_cleanup_errors()
            cleanup_step(cleanup_errors, "write finalizer errors", lambda: write_job(directory, job))
    return exit_code(job)


def resume(directory, fd, lock_path, ticket_fd, ticket_path, deadline):
    directory = Path(directory)
    with os.fdopen(fd, "a+") as live, os.fdopen(ticket_fd, "a+") as ticket:
        return run_job(directory, live, read_job(directory), Path(lock_path), echo=False,
                       owned_ticket=(Path(ticket_path), ticket), deadline=deadline)


def submit(directory, live, job, lock_path):
    # Allocate the ticket before returning the receipt. Runner scheduling must not
    # reverse two completed submissions. Both locked descriptions survive exec.
    script = ("import sys; sys.path.insert(0, sys.argv[1]); import qa_resource as q; "
              "sys.exit(q.resume(sys.argv[2], int(sys.argv[3]), sys.argv[4], "
              "int(sys.argv[5]), sys.argv[6], float(sys.argv[7])))")
    ticket_path = ticket = runner = None
    close_errors = []
    deadline = time.monotonic() + job["admissionDeadline"]
    try:
        ticket_path, ticket = acquire_ticket(directory.parent.parent, job["jobId"], deadline)
        with (directory / "runner.log").open("a") as log:
            with deferred_signals((signal.SIGTERM, signal.SIGINT)) as pending:
                runner = subprocess.Popen([sys.executable, "-c", script, str(Path(__file__).parent),
                                           str(directory), str(live.fileno()), str(lock_path),
                                           str(ticket.fileno()), str(ticket_path), str(deadline)],
                                          pass_fds=(live.fileno(), ticket.fileno()), start_new_session=True,
                                          stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
                # A blocked receipt writer must not keep a finished job alive.
                cleanup_step(close_errors, "close submitted ticket fd", ticket.close)
                cleanup_step(close_errors, "close submitted liveness fd", live.close)
            if pending:
                raise Cancelled(pending[0])
            if close_errors:
                raise RuntimeError("; ".join(close_errors))
        print(json.dumps(dict(jobId=job["jobId"], jobDir=str(directory),
                              resultFile=str(directory / "job.json"), pid=runner.pid)), flush=True)
    except Cancelled:
        return 130
    except Exception as error:
        if runner is not None:
            raise
        job.update(status="admission_timeout" if isinstance(error, DeadlineExpired) else "error",
                   exitCode=75 if isinstance(error, DeadlineExpired) else 125,
                   error=f"cannot submit runner: {error}", finishedAt=timestamp())
        write_job(directory, job)
        return exit_code(job)
    finally:
        # Popen returning proves handoff, even if a later operation fails.
        if runner is not None:
            cleanup_step(close_errors, "close submitted ticket fd", ticket.close)
        else:
            cleanup_step(close_errors, "release unsubmitted ticket",
                         lambda: close_errors.extend(release_ticket(ticket_path, ticket)))
        cleanup_step(close_errors, "close submitted liveness fd", live.close)
        if runner is None and close_errors:
            job.update(status="cleanup_failed", exitCode=125, cleanupError="; ".join(close_errors))
            cleanup_step(close_errors, "write submission cleanup errors", lambda: write_job(directory, job))
    return 0


def live_report(directory):
    with (directory / "live.lock").open("r") as live:
        try:
            fcntl.flock(live, fcntl.LOCK_SH | fcntl.LOCK_NB)
            held = False
        except BlockingIOError:
            held = True
        job = read_job(directory)
        job["live"] = held
        job["stale"] = not held and job["status"] not in TERMINAL
        if job["stale"] and job["childPgid"]:
            try:
                os.killpg(job["childPgid"], 0)
                job["orphanGroupExists"] = True
            except ProcessLookupError:
                job["orphanGroupExists"] = False
            except PermissionError:
                job["orphanGroupExists"] = True
            job["orphanGroupHasLiveMembers"] = group_has_members(job["childPgid"])
        return job


def wait_job(directory, max_wait):
    with (directory / "live.lock").open("r") as live:
        try:
            with bounded(max_wait):
                fcntl.flock(live, fcntl.LOCK_SH)
        except DeadlineExpired:
            print(json.dumps(live_report(directory)))
            return 3
        job = read_job(directory)
        if job["status"] not in TERMINAL:
            job = live_report(directory)
            print(json.dumps(job))
            return 4
        print(json.dumps(job))
        return exit_code(job)


def cancel_job(directory):
    # Keep a shared fd open for inspection, but never signal after lock acquisition.
    with (directory / "live.lock").open("r") as live:
        try:
            fcntl.flock(live, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            job = read_job(directory)
            if not job["runnerPid"] or not job["runnerStart"]:
                print("runner identity is not recorded yet; no signal sent", file=sys.stderr)
                return 4
            try:
                matches = runner_start(job["runnerPid"]) == job["runnerStart"]
            except Exception:
                matches = False
            if not matches:
                print("runner start time does not match; no signal sent", file=sys.stderr)
                return 4
            try:
                # macOS needs per-job IPC to rule out PID reuse between the start-time check and this signal.
                os.kill(job["runnerPid"], signal.SIGTERM)
            except ProcessLookupError:
                print("runner exited; no signal sent", file=sys.stderr)
                return 4
            print(json.dumps(dict(jobId=job["jobId"], cancelRequested=True)))
            return 0
        print(json.dumps(live_report(directory)))
        return 4


def positive_seconds(text):
    value = float(text)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("seconds must be finite and greater than zero")
    return value


def job_id(text):
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", text):
        raise argparse.ArgumentTypeError("job id must match [A-Za-z0-9._-]{1,80}")
    return text


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    # Defaults suppressed on subparsers allow global options before or after command.
    def globals_for(target, suppress=False):
        target.add_argument("--state-dir", type=Path, default=argparse.SUPPRESS if suppress else Path.home() / ".codex/qa-resource")
        target.add_argument("--lock", type=Path, default=argparse.SUPPRESS if suppress else Path.home() / ".codex/local-ios-qa.lock")
    globals_for(parser)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("run", "submit", "wait", "status", "cancel"):
        p = sub.add_parser(name)
        globals_for(p, True)
        p.add_argument("--job-id", type=job_id, required=name != "status")
        if name in ("run", "submit"):
            p.add_argument("--kind", choices=("package", "render", "simulator"), required=True)
            p.add_argument("--device")
            p.add_argument("--cwd", type=Path, required=True)
            p.add_argument("--admission-deadline", type=positive_seconds, required=True)
            p.add_argument("--timeout", type=positive_seconds, required=True)
            p.add_argument("argv", nargs=argparse.REMAINDER)
        elif name == "wait":
            p.add_argument("--max-wait", type=positive_seconds, default=86400)
    args = parser.parse_args(argv)
    args.state_dir = args.state_dir.expanduser().resolve()
    args.lock = args.lock.expanduser().resolve()
    if args.command in ("run", "submit"):
        args.cwd = args.cwd.expanduser().resolve()
        if not args.cwd.is_dir():
            parser.error("--cwd must be an existing directory")
        if (args.kind == "simulator") != bool(args.device):
            parser.error("--device is required only for simulator jobs and rejected for package/render")
        args.argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
        if not args.argv:
            parser.error("argv is required after --")
        try:
            directory, live, job = create_job(args)
        except ValueError as error:
            parser.error(str(error))
        if args.command == "submit":
            return submit(directory, live, job, args.lock)
        return run_job(directory, live, job, args.lock)
    directory = args.state_dir / "jobs" / (args.job_id or "")
    if args.job_id and not (directory / "job.json").is_file():
        print(f"unknown job {args.job_id}: {directory / 'job.json'}", file=sys.stderr)
        return 2
    if args.command == "wait":
        return wait_job(directory, args.max_wait)
    if args.command == "cancel":
        return cancel_job(directory)
    if args.job_id:
        print(json.dumps(live_report(directory)))
    else:
        jobs = [live_report(p) for p in sorted(directory.iterdir()) if (p / "job.json").is_file()] if directory.exists() else []
        queue = args.state_dir / "queue"
        order = sorted(p.name for p in queue.iterdir() if re.match(r"\d{12}\.", p.name)) if queue.exists() else []
        print(json.dumps(dict(jobs=[{key: j[key] for key in ("jobId", "status", "live", "stale")} for j in jobs], queue=order)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
