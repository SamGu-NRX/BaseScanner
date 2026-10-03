#!/usr/bin/env python3
"""Serialize heavyweight local QA work without taking ownership of other jobs."""
import argparse
from contextlib import closing, contextmanager
import ctypes
from datetime import datetime, timezone
import errno
import fcntl
from functools import lru_cache
import json
import math
import os
from pathlib import Path
import re
import select
import secrets
import shlex
import signal
import stat
import subprocess
import sys
import threading
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
OWNER_ENV_PREFIX = "QA_RESOURCE_OWNER_"
_LIBC = ctypes.CDLL(None, use_errno=True)
_SYSCTL = _LIBC.sysctl
_SYSCTL.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                   ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
_SYSCTL.restype = ctypes.c_int
HEAVY_NAMES = {"xcodebuild", "swift-build", "swift-test", "swift-frontend",
               "swift-driver", "blender"}
SERVICE_TEST = "AgentDeviceRunnerUITests/RunnerTests/testCommand"
CANCEL_FIFO = "cancel.fifo"
STOP_LISTENER = b"q"
TERMINAL = {"succeeded", "failed", "timed_out", "cancelled", "admission_timeout",
            "error", "cleanup_failed"}



def is_heavy(comm):
    # Compare case-insensitively: Blender.app's executable is .../Contents/MacOS/Blender.
    return Path(comm).name.lower() in HEAVY_NAMES

class Cancelled(Exception):
    def __init__(self, signum):
        self.signum = signum


class DeadlineExpired(Exception):
    pass


class SnapshotIncomplete(RuntimeError):
    def __init__(self, message, processes=()):
        super().__init__(message)
        self.processes = list(processes)


class SnapshotDeadline(SnapshotIncomplete):
    pass


def inspection_timeout(deadline):
    if deadline is None:
        return SENSING_TIMEOUT
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise SnapshotDeadline("inspection deadline expired; completeness uncertain")
    return min(SENSING_TIMEOUT, remaining)


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


def command_output(argv, timeout=SENSING_TIMEOUT):
    # subprocess.run kills a timed-out helper, but its subsequent reap is unbounded.
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
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


def _sysctl_read(mib, buffer):
    size = ctypes.c_size_t(ctypes.sizeof(buffer))
    name = (ctypes.c_int * len(mib))(*mib)
    if _SYSCTL(name, len(mib), ctypes.byref(buffer), ctypes.byref(size), None, 0):
        code = ctypes.get_errno()
        raise OSError(code, f"sysctl {mib}: {os.strerror(code)}")
    return size.value


@lru_cache(maxsize=1)
def _argmax():
    value = ctypes.c_int()
    _sysctl_read([1, 8], value)  # CTL_KERN, KERN_ARGMAX, from Darwin sys/sysctl.h.
    if value.value <= 0:
        raise OSError(errno.EINVAL, "KERN_ARGMAX returned a nonpositive buffer size")
    return value.value


def parse_process_env(raw, pid):
    """Return NUL-separated candidates after the executable, including argv strings."""
    end = raw.find(b"\0", ctypes.sizeof(ctypes.c_int))
    if len(raw) < ctypes.sizeof(ctypes.c_int) or end < 0:
        raise OSError(errno.EINVAL, f"malformed KERN_PROCARGS2 data for process {pid}")
    # Empty argv[0] is indistinguishable from padding. Never use argc to skip it.
    # These are cooperative markers in mutable process memory, not exec records.
    return [os.fsdecode(entry) for entry in raw[end + 1:].split(b"\0") if entry]


def process_env(pid):
    # Darwin can omit cs_restricted environments without reporting an error.
    buffer = ctypes.create_string_buffer(_argmax())
    size = _sysctl_read([1, 49, pid], buffer)  # CTL_KERN, KERN_PROCARGS2.
    return parse_process_env(ctypes.string_at(buffer, size), pid)


class ProcessTimeval(ctypes.Structure):
    _fields_ = [("seconds", ctypes.c_long), ("microseconds", ctypes.c_int)]


def kernel_identity(pid):
    # 64-bit Darwin SDK sizeof/offsetof: kinfo_proc=648, start=0, stat=36,
    # pid=40, kp_eproc.e_ucred.cr_uid=420. Fail closed if the runtime ABI differs.
    if ctypes.sizeof(ctypes.c_void_p) != 8 or ctypes.sizeof(ProcessTimeval) != 16:
        raise RuntimeError("process identity requires the 64-bit Darwin kinfo_proc ABI")
    buffer = ctypes.create_string_buffer(648)
    try:
        size = _sysctl_read([1, 14, 1, pid], buffer)  # CTL_KERN, KERN_PROC, KERN_PROC_PID.
    except OSError as error:
        if error.errno == errno.ESRCH:
            return None
        raise
    if size == 0:
        return None
    if size != ctypes.sizeof(buffer):
        raise RuntimeError(f"kinfo_proc size mismatch for PID {pid}: expected 648, got {size}")
    actual_pid = ctypes.c_int.from_buffer(buffer, 40).value
    if actual_pid != pid:
        raise RuntimeError(f"kinfo_proc PID mismatch: requested {pid}, got {actual_pid}")
    start = ProcessTimeval.from_buffer(buffer)
    if start.seconds <= 0 or not 0 <= start.microseconds < 1_000_000:
        raise RuntimeError(f"invalid kinfo_proc start time for PID {pid}")
    return dict(pid=pid, start_us=start.seconds * 1_000_000 + start.microseconds,
                uid=ctypes.c_uint.from_buffer(buffer, 420).value,
                zombie=ctypes.c_byte.from_buffer(buffer, 36).value == 5)


def process_snapshot(deadline=None):
    rows = command_output(["ps", "-axo", "pid=,ppid=,pgid=,uid=,stat="],
                          timeout=inspection_timeout(deadline))
    result = {}
    for row in rows.splitlines():
        pid, ppid, pgid, uid, state = row.split()
        result[int(pid)] = dict(pid=int(pid), ppid=int(ppid), pgid=int(pgid),
                                uid=int(uid), stat=state)
    return result


def process_identity(pid, details=False, deadline=None):
    columns = "pid=,ppid=,pgid=,uid=,stat=,lstart=,comm=" if details else "lstart=,comm="
    result = subprocess.run(["ps", "-o", columns, "-p", str(pid)], capture_output=True,
                            text=True, timeout=inspection_timeout(deadline))
    if result.returncode == 1 and not result.stdout.strip():
        return None
    if result.returncode:
        raise RuntimeError(f"cannot inspect identity for process {pid}: {result.stderr.strip()}")
    text = result.stdout.strip()
    identity = dict(pid=pid)
    if details:
        fields = text.split(maxsplit=5)
        if len(fields) != 6:
            raise RuntimeError(f"malformed process details for {pid}: {text!r}")
        identity.update(pid=int(fields[0]), ppid=int(fields[1]), pgid=int(fields[2]),
                        uid=int(fields[3]), stat=fields[4])
        text = fields[5]
    match = re.fullmatch(r"(\S+\s+\S+\s+\d+\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.+)", text)
    if match is None:
        raise RuntimeError(f"malformed lstart/comm for process {pid}: {text!r}")
    identity.update(start=match[1], comm=match[2])
    return identity


def process_ancestors(pid, rows):
    ancestors = set()
    while pid in rows:
        pid = rows[pid]["ppid"]
        if not pid or pid in ancestors:
            break
        ancestors.add(pid)
    return ancestors


def owner_entry(job):
    token = job.get("ownerToken")
    return f"{OWNER_ENV_PREFIX}{token}={job['jobId']}" if token else None


def owned_processes(job, child_pid, deadline=None, known=None, observed=None):
    deadline = time.monotonic() + SENSING_TIMEOUT if deadline is None else deadline
    owned = []
    try:
        rows = process_snapshot(deadline)
        root = rows.get(child_pid)
        # After natural exit, already-reparented tokenless helpers have no ancestry.
        root_alive = root is not None and not root["stat"].startswith("Z")
        entry = owner_entry(job)
        for pid, row in rows.items():
            inspection_timeout(deadline)
            if pid == os.getpid() or row["stat"].startswith("Z"):
                continue
            ancestry = root_alive and (pid == child_pid or child_pid in process_ancestors(pid, rows))
            if row["uid"] != os.getuid() and not ancestry:
                continue
            before = kernel_identity(pid)
            inspection_timeout(deadline)
            if before is None or before["zombie"]:
                continue
            key = identity_key(before)
            if known is not None and key in known:
                owned.append(dict(known[key], pgid=row["pgid"], ppid=row["ppid"], stat=row["stat"]))
                continue  # Historical proof is attached to this exact execution.
            token = False
            if before["uid"] == os.getuid() and entry is not None:
                try:
                    token = entry in process_env(pid)
                except OSError as error:
                    if error.errno == errno.ESRCH:
                        continue  # Enumeration-to-env disappearance is settled-gone.
                    # Restricted or unreadable environments alone are not proof.
            inspection_timeout(deadline)
            if not token and not ancestry:
                continue
            if observed is not None:
                observed.append(pid)
            identity = process_identity(pid, deadline=deadline)
            after = kernel_identity(pid)
            inspection_timeout(deadline)
            if after is None or after["zombie"] or after["start_us"] != before["start_us"]:
                continue  # This identity is settled-gone, not a live empty read.
            if identity is None or after["uid"] != before["uid"]:
                raise SnapshotIncomplete(f"unsettled owned identity for PID {pid}", owned)
            owned.append(dict(row, **{k: identity[k] for k in ("start", "comm")},
                              start_us=after["start_us"], uid=after["uid"],
                              proof="token" if token else "ancestry"))
        inspection_timeout(deadline)
    except SnapshotIncomplete as error:
        error.processes = owned
        raise
    except subprocess.TimeoutExpired as error:
        failure = SnapshotDeadline if time.monotonic() >= deadline else SnapshotIncomplete
        raise failure(f"process inspection timed out: {error}; completeness uncertain", owned) from error
    except Exception as error:
        raise SnapshotIncomplete(f"process discovery failed: {error}", owned) from error
    return owned


def owner_jobs(entries):
    pattern = re.compile(r"^" + re.escape(OWNER_ENV_PREFIX) + r"[0-9a-f]{32}=")
    return [entry[match.end():] for entry in entries if (match := pattern.match(entry))]


def owner_blockers():
    rows = process_snapshot()
    excluded = process_ancestors(os.getpid(), rows) | {os.getpid()}
    pids, reasons = [], []
    for pid, row in rows.items():
        if pid in excluded or row["uid"] != os.getuid() or row["stat"].startswith("Z"):
            continue
        try:
            owners = owner_jobs(process_env(pid))
        except OSError:
            continue
        if not owners:
            continue
        identity = process_identity(pid)
        if identity is None:
            continue
        pids.append(pid)
        reasons.extend(f"process {pid} ({identity['comm']}) still carries owner token of job {owner}"
                       for owner in owners)
    return pids, reasons


def signal_owned_process(identity, signum):
    """Ownership proof survives reparenting; recheck the exact proven identity."""
    current = kernel_identity(identity["pid"])
    if (current is None or current["start_us"] != identity["start_us"]
            or current["uid"] != identity["uid"] or current["uid"] != os.getuid()
            or current["zombie"]):
        return False
    try:
        # Microsecond identity prevents coarse lstart reuse, not this final race.
        os.kill(current["pid"], signum)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def list_processes():
    rows = command_output(["ps", "-axo", "pid=,pgid=,stat=,comm="])
    processes = []
    for row in rows.splitlines():
        pid, pgid, state, comm = row.strip().split(maxsplit=3)
        if int(pid) == os.getpid() or state.startswith("Z") or not is_heavy(comm):
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
    if process.get("stat", "").startswith("Z") or not is_heavy(process["comm"]):
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


def group_has_members(pgid, deadline=None):
    rows = command_output(["ps", "-axo", "pgid=,stat="],
                          timeout=inspection_timeout(deadline))
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


def identity_key(identity):
    return identity["pid"], identity["start_us"], identity["uid"]


class OwnedProcesses:
    """Keep discovery proof attached to an exact identity until that execution ends."""
    def __init__(self, job, child_pid, report=None):
        self.job, self.child_pid, self.report = job, child_pid, report
        self.identities, self.sent, self.escaped = {}, {}, {}
        self.errors = []
        self.last_incomplete = None
        self.saw_owned = False

    def error(self, message):
        if message not in self.errors:
            self.errors.append(message)

    def record(self, identity, outcome):
        key = identity_key(identity)
        if self.escaped.get(key) != outcome:
            self.escaped[key] = outcome
            if self.report is not None:
                self.report(identity, outcome)

    def snapshot(self, deadline):
        complete = True
        self.last_incomplete = None
        observed = []
        try:
            fresh = owned_processes(self.job, self.child_pid, deadline,
                                    known=self.identities, observed=observed)
        except SnapshotIncomplete as error:
            fresh, complete = error.processes, False
            self.last_incomplete = str(error)
            if not isinstance(error, SnapshotDeadline):
                self.error(str(error))
        except Exception as error:
            fresh, complete = [], False
            self.last_incomplete = str(error)
            self.error(str(error))
        current = {identity_key(p): p for p in fresh}
        for key, previous in list(self.identities.items()):
            if key in current:
                continue
            current[key] = previous  # An uninspected identity is not an empty result.
            try:
                inspection_timeout(deadline)
                identity = kernel_identity(previous["pid"])
                inspection_timeout(deadline)
            except Exception as error:
                complete = False
                self.last_incomplete = str(error)
                if not isinstance(error, SnapshotDeadline):
                    self.error(str(error))
                if isinstance(error, SnapshotDeadline):
                    # Retain the rest without inspecting beyond this pass's budget.
                    current.update({k: p for k, p in self.identities.items() if k not in current})
                    break
                continue
            if identity is None or identity["zombie"] or identity["start_us"] != previous["start_us"]:
                current.pop(key)
                self.identities.pop(key)
                if key in self.escaped:
                    outcome = {signal.SIGTERM: "terminated", signal.SIGKILL: "killed"}.get(
                        self.sent.get(key), "exited")
                    self.record(previous, outcome)
                self.sent.pop(key, None)
        for key, identity in current.items():
            self.identities[key] = identity
            if identity["pgid"] != self.child_pid and key not in self.escaped:
                self.record(identity, "retained")
        if time.monotonic() >= deadline:
            complete = False
            self.last_incomplete = "inspection deadline expired; completeness uncertain"
        self.saw_owned = bool(observed) or bool(current)
        return list(current.values()), complete

    def signal(self, identities, signum):
        for identity in identities:
            key = identity_key(identity)
            if identity["pgid"] == self.child_pid or self.sent.get(key) == signum:
                continue
            try:
                if signal_owned_process(identity, signum):
                    self.sent[key] = signum
            except Exception as error:
                self.error(f"signal escaped PID {identity['pid']}: {error}")

    def retained(self, identities):
        for identity in identities:
            if identity_key(identity) in self.escaped:
                self.record(identity, "retained")
        return "; ".join(f"PID {p['pid']} ({p['comm']}) start {p['start']} "
                         f"start_us {p['start_us']} uid {p['uid']}" for p in identities)


def owned_state(child, owned, deadline):
    remaining, complete = owned.snapshot(deadline)
    try:
        group_live = group_has_members(child.pid, deadline=deadline)
    except Exception as error:
        group_live, complete = None, False
        owned.last_incomplete = str(error)
        if not isinstance(error, SnapshotDeadline) and not (
                isinstance(error, subprocess.TimeoutExpired) and time.monotonic() >= deadline):
            owned.error(f"inspect pinned group: {error}")
    if time.monotonic() >= deadline:
        complete = False
        owned.last_incomplete = "inspection deadline expired; completeness uncertain"
    return remaining, group_live, complete


def confirm_owned_exit(child, owned, deadline, escalate=True, poll_seconds=.1):
    empty_at = None
    while True:
        remaining, group_live, complete = owned_state(child, owned, deadline)
        now = time.monotonic()
        if now < deadline and complete and not remaining and not group_live and not owned.saw_owned:
            if empty_at is not None and now - empty_at >= .1:
                return
            empty_at = now if empty_at is None else empty_at
        else:
            empty_at = None
            if escalate:
                owned.signal(remaining, signal.SIGKILL)
        if now >= deadline:
            retained = owned.retained(remaining)
            raise RuntimeError("completeness uncertain; "
                               + (f"live members remained; retained: {retained or 'pinned group'}"
                                  if remaining or group_live else ("live membership unknown; no two complete empty passes"
                                  if not complete else "no two complete empty passes"))
                               + (f"; {owned.last_incomplete}" if owned.last_incomplete else ""))
        # Two complete empty passes reduce successor races, but a chain shorter
        # than a scan interval can still be invisible between both passes.
        delay = .1 if empty_at is not None else poll_seconds
        time.sleep(min(delay, deadline - now))


def stop_owned_command(child, owned=None):
    if child is None:
        return None
    owned = owned if owned is not None else OwnedProcesses({}, child.pid)
    remaining, complete = owned.snapshot(time.monotonic() + SENSING_TIMEOUT)
    if not complete:
        owned.error("initial discovery incomplete: " + (owned.last_incomplete or "unknown reason"))
    # Signal discovered escapes first. Their identity stays proven even if their
    # parents die on the group SIGTERM and launchd adopts them immediately.
    owned.signal(remaining, signal.SIGTERM)
    # Discovery failures must never skip either signal to the pinned group.
    try:
        signal_owned_group(child.pid, signal.SIGTERM)
    except Exception as error:
        owned.error(f"SIGTERM pinned group: {error}")
    deadline = time.monotonic() + CLEANUP_GRACE_SECONDS
    while True:
        remaining, group_live, complete = owned_state(child, owned, deadline)
        if complete and not group_live and not remaining:
            break
        owned.signal(remaining, signal.SIGTERM)
        if time.monotonic() >= deadline:
            owned.signal(remaining, signal.SIGKILL)
            try:
                signal_owned_group(child.pid, signal.SIGKILL)
            except Exception as error:
                owned.error(f"SIGKILL pinned group: {error}")
            break
        time.sleep(min(.1, max(0, deadline - time.monotonic())))
    try:
        confirm_owned_exit(child, owned, time.monotonic() + CLEANUP_CONFIRM_SECONDS)
    except Exception as error:
        if owned.errors:
            raise RuntimeError(f"{error}; " + "; ".join(owned.errors)) from error
        raise
    if owned.errors:
        raise RuntimeError("cleanup discovery or signaling failed: " + "; ".join(owned.errors))
    # Never poll or reap before the final complete pass: the leader pins its pgid.
    return child.wait(timeout=CLEANUP_CONFIRM_SECONDS)


def hold_owned_group(child, owned=None):
    owned = owned if owned is not None else OwnedProcesses({}, child.pid)
    try:
        confirm_owned_exit(child, owned, time.monotonic() + CLEANUP_HOLD_SECONDS,
                           escalate=False, poll_seconds=1)
        return "no live members remained when the shared QA lock was released"
    except Exception as error:
        return (f"{error} when the shared QA lock was released "
                "after the cleanup hold expired")


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
               ownerToken=secrets.token_hex(16), escapedProcesses=[], cancelChannel=CANCEL_FIFO,
               ignoredProcesses=[], logs={name: str(directory / (name + ".log"))
                                         for name in ("output", "runner")})
    write_job(directory, job)
    try:
        (directory / "output.log").touch()
        (directory / "runner.log").touch()
        os.mkfifo(directory / CANCEL_FIFO, 0o600)
    except OSError as error:
        raise fail_unstarted_job(directory, live, job, f"cannot set up job files: {error}") from error
    return directory, live, job


class JobSetupError(RuntimeError):
    pass


def fail_unstarted_job(directory, live, job, message):
    """Record a terminal error for a job whose runner never started, then drop its lock.

    Without this the job would stay `queued` with no runner, `wait` would report it stale,
    and its id could not be reused.
    """
    job.update(status="error", exitCode=125, error=message, finishedAt=timestamp())
    try:
        write_job(directory, job)
    finally:
        live.close()
    return JobSetupError(f"job {job['jobId']}: {message}")


class CancelListener:
    """Turn a byte on the job's FIFO into SIGTERM for this runner's main thread.

    `cancel` never signals a PID. It can write only while the job's read end is open; once
    the runner is gone the open fails with ENXIO, so a reused PID is never reached.
    The caller owns this object as soon as it exists, so a cancel that interrupts
    start() still reaches stop() in cleanup.
    """

    def __init__(self, directory, fd=None):
        # The job's creator opens the read end before the runner starts and hands it over, so a
        # cancel sent during runner startup waits in the pipe instead of failing with ENXIO.
        self.fd = open_cancel_reader(directory) if fd is None else fd
        self.thread = None
        self.active = True
        self.guard = threading.Lock()
        self.main = threading.main_thread().ident

    def _listen(self):
        while True:
            try:
                byte = os.read(self.fd, 1)
            except OSError:
                return
            if not byte or byte == STOP_LISTENER:
                return
            with self.guard:
                # stop() clears this first, so nothing is delivered once cleanup has begun.
                if self.active:
                    signal.pthread_kill(self.main, signal.SIGTERM)

    def start(self):
        # Start the thread with every signal blocked, so SIGALRM, SIGTERM and SIGINT keep
        # interrupting the main thread's flock, sleep and kqueue waits. A cancel read before
        # the mask is restored is raised here, after self.thread is recorded.
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, signal.valid_signals())
        try:
            self.thread = threading.Thread(target=self._listen, name="qa-resource-cancel", daemon=True)
            self.thread.start()
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)

    def stop(self):
        with self.guard:
            self.active = False
        if self.thread is None:
            os.close(self.fd)
            return
        # Closing an fd while another thread is blocked reading it can hang on macOS, so
        # close only after the thread has provably exited. Otherwise leave it for process exit.
        os.write(self.fd, STOP_LISTENER)
        self.thread.join(timeout=CLEANUP_CONFIRM_SECONDS)
        if self.thread.is_alive():
            raise RuntimeError("cancel listener did not exit; its FIFO fd stays open until the runner exits")
        os.close(self.fd)


def open_cancel_reader(directory):
    # O_RDWR keeps a writer open too, so read blocks instead of returning EOF. Not inheritable.
    return os.open(directory / CANCEL_FIFO, os.O_RDWR)


def ignore_runner_signals(signals):
    for sig in signals:
        signal.signal(sig, signal.SIG_IGN)


def acquire_ticket(state_dir, job_id, deadline):
    queue = state_dir / "queue"
    queue.mkdir(parents=True, exist_ok=True)
    with (queue / ".guard").open("a+") as guard:
        with bounded(deadline - time.monotonic()):
            fcntl.flock(guard, fcntl.LOCK_EX)
        counter = queue / "counter"
        seq = int(counter.read_text()) + 1 if counter.exists() else 1
        # Replace atomically: a truncated counter would fail every later submission.
        temporary = queue / "counter.tmp"
        temporary.write_text(str(seq))
        os.replace(temporary, counter)
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


def run_job(directory, live, job, lock_path, echo=True, owned_ticket=None, deadline=None,
            cancel_fd=None):
    global_lock = child = owned = None
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
    def report_escaped(identity, outcome):
        record = {key: identity[key] for key in ("pid", "start_us", "uid", "start", "comm", "proof")}
        record["outcome"] = outcome
        records = job.setdefault("escapedProcesses", [])
        records[:] = [p for p in records if (p["pid"], p.get("start_us"), p.get("uid")) !=
                      identity_key(record)] + [record]
        cleanup_step(cleanup_errors, "record escaped process",
                     lambda: update(escapedProcesses=records))
    def interrupted(signum, frame):
        # A second signal must not escape while the first exception is handled.
        for sig in RUNNER_SIGNALS:
            signal.signal(sig, signal.SIG_IGN)
        raise Cancelled(signum)
    old_signals = {sig: signal.signal(sig, interrupted) for sig in RUNNER_SIGNALS}
    listener = None
    try:
        # submit starts the runner with these blocked; a cancel that arrived meanwhile is
        # raised here, inside the try, so it still gets a terminal result and cleanup.
        signal.pthread_sigmask(signal.SIG_UNBLOCK, RUNNER_SIGNALS)
        if cancel_fd is not None or (directory / CANCEL_FIFO).exists():
            listener = CancelListener(directory, cancel_fd)
            cancel_fd = None
            listener.start()
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
                heavy, owner_reasons = owner_blockers()
                reasons.extend(owner_reasons)
                ignored = []
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
                environment = os.environ.copy()
                if job.get("ownerToken") is None:
                    job["ownerToken"] = secrets.token_hex(16)
                environment[f"{OWNER_ENV_PREFIX}{job['ownerToken']}"] = job["jobId"]
                child = subprocess.Popen(job["argv"], cwd=job["cwd"], start_new_session=True,
                                         env=environment, stdin=subprocess.DEVNULL,
                                         stdout=output, stderr=subprocess.STDOUT)
                owned = OwnedProcesses(job, child.pid, report_escaped)
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
        try:
            ignore_runner_signals(old_signals)
        except Cancelled:
            # The one-shot handler fired as cleanup began. It already ignores further signals,
            # and the job's outcome was settled before cleanup, so cleanup simply continues.
            ignore_runner_signals(old_signals)
        if listener is not None:
            cleanup_step(cleanup_errors, "stop cancel listener", listener.stop)
        elif cancel_fd is not None:
            cleanup_step(cleanup_errors, "close cancel fd", lambda: os.close(cancel_fd))
        try:
            code = stop_owned_command(child, owned)
            if child_finished and job["status"] == "running":
                job.update(status="succeeded" if code == 0 else "failed", exitCode=code,
                           signal=-code if code < 0 else None)
        except Exception as error:
            cleanup_errors.append(f"stop owned group: {error}")
            mark_cleanup_errors()
            cleanup_step(cleanup_errors, "write cleanup hold status", lambda: write_job(directory, job))
            if child is not None:
                try:
                    cleanup_errors.append(hold_owned_group(child, owned))
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


def resume(directory, fd, lock_path, ticket_fd, ticket_path, deadline, cancel_fd):
    directory = Path(directory)
    with os.fdopen(fd, "a+") as live, os.fdopen(ticket_fd, "a+") as ticket:
        return run_job(directory, live, read_job(directory), Path(lock_path), echo=False,
                       owned_ticket=(Path(ticket_path), ticket), deadline=deadline,
                       cancel_fd=cancel_fd)


def submit(directory, live, job, lock_path, cancel_fd):
    # Allocate the ticket before returning the receipt. Runner scheduling must not
    # reverse two completed submissions. Both locked descriptions survive exec.
    script = ("import sys; sys.path.insert(0, sys.argv[1]); import qa_resource as q; "
              "sys.exit(q.resume(sys.argv[2], int(sys.argv[3]), sys.argv[4], "
              "int(sys.argv[5]), sys.argv[6], float(sys.argv[7]), int(sys.argv[8])))")
    ticket_path = ticket = runner = None
    close_errors = []
    deadline = time.monotonic() + job["admissionDeadline"]
    try:
        ticket_path, ticket = acquire_ticket(directory.parent.parent, job["jobId"], deadline)
        # Keep SIGCHLD at its default so an exited runner stays an unreaped zombie and its PID
        # cannot be reused before an interrupted submit signals it. An inherited SIG_IGN
        # would make the kernel reap it at once.
        previous_sigchld = signal.signal(signal.SIGCHLD, signal.SIG_DFL)
        try:
            pending = []
            def record(signum, frame):
                if not pending:
                    pending.append(signum)
            def interrupt(signum, frame):
                # One-shot, so a second signal cannot escape the cancellation below.
                for sig in RUNNER_SIGNALS:
                    signal.signal(sig, signal.SIG_IGN)
                raise Cancelled(signum)
            previous_handlers = {sig: signal.signal(sig, record) for sig in RUNNER_SIGNALS}
            try:
                with (directory / "runner.log").open("a") as log:
                    # The runner inherits this mask and unblocks after installing its handlers,
                    # so a SIGTERM sent to it right after spawn still gets a clean cancellation.
                    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, RUNNER_SIGNALS)
                    try:
                        runner = subprocess.Popen([sys.executable, "-c", script, str(Path(__file__).parent),
                                                   str(directory), str(live.fileno()), str(lock_path),
                                                   str(ticket.fileno()), str(ticket_path), str(deadline),
                                                   str(cancel_fd)],
                                                  pass_fds=(live.fileno(), ticket.fileno(), cancel_fd),
                                                  start_new_session=True,
                                                  stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
                    finally:
                        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                # A blocked receipt writer must not keep a finished job alive, or keep the
                # cancel FIFO open after its runner is gone.
                cleanup_step(close_errors, "close submitted ticket fd", ticket.close)
                cleanup_step(close_errors, "close submitted liveness fd", live.close)
                cleanup_step(close_errors, "close submitted cancel fd", lambda: os.close(cancel_fd))
                cancel_fd = None
                receipt = dict(jobId=job["jobId"], jobDir=str(directory),
                               resultFile=str(directory / "job.json"), pid=runner.pid)
                printing = False
                # From here an interruption cancels the job instead of abandoning it, and a
                # submitter blocked on a full stdout pipe can still be stopped.
                for sig in RUNNER_SIGNALS:
                    signal.signal(sig, interrupt)
                try:
                    if pending:
                        raise Cancelled(pending[0])
                    printing = True
                    write_receipt(receipt)
                except Cancelled:
                    # Still our unreaped child (SIGCHLD is default and nothing here waits on
                    # it), so this PID cannot belong to another process.
                    os.kill(runner.pid, signal.SIGTERM)
                    # An interrupted write means stdout itself was blocked, usually a pipe
                    # nobody drains. Writing again would block again and make this submitter
                    # unstoppable, so only a receipt that never started is written here.
                    if not printing:
                        receipt["cancelRequested"] = True
                        for sig, handler in previous_handlers.items():
                            signal.signal(sig, handler)
                        write_receipt(receipt)
                    return 130
            finally:
                for sig, handler in previous_handlers.items():
                    signal.signal(sig, handler)
            if close_errors:
                raise RuntimeError("; ".join(close_errors))
        finally:
            signal.signal(signal.SIGCHLD, previous_sigchld)
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
        if cancel_fd is not None:
            cleanup_step(close_errors, "close cancel fd", lambda: os.close(cancel_fd))
        if runner is None and close_errors:
            job.update(status="cleanup_failed", exitCode=125, cleanupError="; ".join(close_errors))
            cleanup_step(close_errors, "write submission cleanup errors", lambda: write_job(directory, job))
    return 0


def write_receipt(receipt):
    # Unbuffered, so an interrupted write leaves nothing for exit to flush into a full pipe.
    sys.stdout.flush()
    data = (json.dumps(receipt) + "\n").encode()
    while data:
        data = data[os.write(sys.stdout.fileno(), data):]


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
    # Cancellation never signals a PID. It writes one byte to the job's FIFO, which only the
    # live runner reads; with no reader the open fails, so nothing else can receive it.
    with (directory / "live.lock").open("r") as live:
        try:
            fcntl.flock(live, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            job = read_job(directory)
            if not job.get("cancelChannel"):
                print(f"job {job.get('jobId', directory.name)} was started by a runner without a cancel channel; "
                      "this version never signals a runner PID, so use the qa_resource.py that "
                      "started it; no signal sent", file=sys.stderr)
                return 4
            try:
                fd = os.open(directory / CANCEL_FIFO, os.O_WRONLY | os.O_NONBLOCK)
            except OSError as error:
                if error.errno in (errno.ENXIO, errno.ENOENT):
                    print("runner is not listening for cancellation; no signal sent", file=sys.stderr)
                    return 4
                raise
            try:
                if not stat.S_ISFIFO(os.fstat(fd).st_mode):
                    print(f"{directory / CANCEL_FIFO} is not a FIFO; nothing sent", file=sys.stderr)
                    return 4
                try:
                    os.write(fd, b"c")
                except BrokenPipeError:
                    print("runner stopped listening for cancellation; no signal sent", file=sys.stderr)
                    return 4
            finally:
                os.close(fd)
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
        owners = owner_jobs(f"{key}={value}" for key, value in os.environ.items())
        if owners:
            parser.error(f"nested qa-resource jobs are not supported: this process belongs to job {owners[0]}")
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
            # Hold the cancel FIFO's read end from job creation, so a cancel sent before the
            # runner's listener starts is queued in the pipe rather than refused.
            try:
                cancel_fd = open_cancel_reader(directory)
            except OSError as error:
                raise fail_unstarted_job(directory, live, job, f"cannot open the cancel FIFO: {error}") from error
        except ValueError as error:
            parser.error(str(error))
        except JobSetupError as error:
            print(str(error), file=sys.stderr)
            return 125
        if args.command == "submit":
            return submit(directory, live, job, args.lock, cancel_fd)
        return run_job(directory, live, job, args.lock, cancel_fd=cancel_fd)
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
