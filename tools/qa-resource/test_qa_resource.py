import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).with_name("qa_resource.py")
spec = importlib.util.spec_from_file_location("qa_resource", SCRIPT)
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)

# Only test-side code sees this configuration. Production has no test switches.
FAKE = r'''#!PYTHON
import json, os, subprocess, sys, time
from pathlib import Path
config = json.loads(Path(os.environ['QA_TEST_CONFIG']).read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'sysctl':
    print(config.get('pressure', 1))
elif name == 'memory_pressure':
    print(config.get('memory', 'System-wide memory free percentage: 80%'))
elif name == 'df':
    print('Filesystem 1024-blocks Used Available Capacity Mounted on')
    print('fake 20000000 1 10000000 1% /')
elif name == 'ps':
    if args == ['-axo', 'pid=,pgid=,stat=,comm=']:
        for p in config.get('processes', []):
            print(p, p, 'S', '/a path with spaces/blender')
    else:
        result = subprocess.run(['/bin/ps', *args])
        sys.exit(result.returncode)
elif name == 'xcrun':
    with open(config['calls'], 'a') as log:
        log.write(json.dumps(args) + '\n')
    operation = args[1]
    if operation == 'list':
        print(json.dumps({'devices': {'fake': config.get('devices', [])}}))
    elif operation == 'boot':
        if config.get('bootState'):
            for device in config['devices']:
                if device['udid'] == args[2]:
                    device['state'] = config['bootState']
            config_path = Path(os.environ['QA_TEST_CONFIG'])
            temporary = config_path.with_suffix('.boot.tmp')
            temporary.write_text(json.dumps(config))
            temporary.replace(config_path)
        time.sleep(config.get('bootSleep', 0))
        sys.exit(config.get('bootCode', 0))
    elif operation == 'bootstatus':
        sys.exit(config.get('bootstatusCode', 0))
    elif operation == 'shutdown':
        sys.exit(config.get('shutdownCode', 0))
    else:
        sys.exit(99)
else:
    sys.exit(99)
'''
BOOTSTRAP = ("import sys; sys.path.insert(0, sys.argv[1]); import qa_resource as q; "
             "q.CLEANUP_GRACE_SECONDS=.2; q.RESAMPLE_SECONDS=.1; "
             "sys.exit(q.main(sys.argv[2:]))")


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.state = self.root / "state"
        self.lock = self.root / "shared.lock"
        self.config_path = self.root / "config.json"
        self.calls_path = self.root / "simctl-calls"
        self.config = dict(calls=str(self.calls_path), devices=[dict(udid="ours", state="Shutdown"),
                                                             dict(udid="other", state="Booted")])
        self.configure()
        binary = self.root / "bin"
        binary.mkdir()
        for name in ("sysctl", "memory_pressure", "df", "ps", "xcrun"):
            path = binary / name
            path.write_text(FAKE.replace("PYTHON", sys.executable, 1))
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ.get("PATH", ""),
                        QA_TEST_CONFIG=str(self.config_path))
        self.processes = []
        self.detached = []

    def tearDown(self):
        for receipt in self.detached:
            directory = Path(receipt["jobDir"])
            if qa.live_report(directory)["live"]:
                self.invoke(self.cli("cancel", receipt["jobId"]))
                result = self.invoke(self.cli("wait", receipt["jobId"], ["--max-wait", "3"]))
                if result.returncode == 3:
                    job = qa.read_job(directory)
                    if job["runnerPid"] == receipt["pid"] and qa.runner_start(receipt["pid"]) == job["runnerStart"]:
                        os.kill(receipt["pid"], signal.SIGKILL)
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=4)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream:
                    stream.close()
        # Every directory here was created by this test. These groups belong to
        # its spawned jobs, including the orphan deliberately made by SIGKILL.
        jobs = self.state / "jobs"
        if jobs.exists():
            for directory in jobs.iterdir():
                if (directory / "job.json").exists():
                    pgid = qa.read_job(directory)["childPgid"]
                    if pgid and qa.group_has_members(pgid):
                        qa.signal_owned_group(pgid, signal.SIGKILL)
        self.temporary.cleanup()

    def configure(self, **changes):
        self.config.update(changes)
        temporary = self.config_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.config))
        temporary.replace(self.config_path)

    def cli(self, command, job=None, extra=()):
        args = [command, "--state-dir", str(self.state), "--lock", str(self.lock)]
        if job:
            args += ["--job-id", job]
        return args + list(extra)

    def job_args(self, job, code="pass", kind="package", deadline=8, timeout=3, device=None):
        args = ["--kind", kind, "--cwd", str(self.root), "--admission-deadline", str(deadline),
                "--timeout", str(timeout)]
        if device:
            args += ["--device", device]
        return self.cli("run", job, args + ["--", sys.executable, "-c", code])

    def launch(self, args, bootstrap=BOOTSTRAP):
        process = subprocess.Popen([sys.executable, "-c", bootstrap, str(SCRIPT.parent), *args],
                                   env=self.env, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(process)
        return process

    def invoke(self, args):
        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                                capture_output=True, text=True, timeout=10)
        if args[0] == "submit" and result.returncode == 0:
            self.detached.append(json.loads(result.stdout))
        return result

    def job(self, name):
        return json.loads((self.state / "jobs" / name / "job.json").read_text())

    def await_job(self, name, predicate, seconds=5):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                job = self.job(name)
                if predicate(job):
                    return job
            except FileNotFoundError:
                pass
            time.sleep(.02)
        self.fail(f"job {name} did not reach expected state; last={self.job(name)}")

    def finish(self, process, name, expected):
        output, error = process.communicate(timeout=8)
        self.assertEqual(process.returncode, expected, (output, error, self.job(name)))
        return self.job(name)

    def assert_lock_free(self):
        with self.lock.open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def calls(self):
        return [json.loads(row) for row in self.calls_path.read_text().splitlines()] if self.calls_path.exists() else []

    def sleeper(self, seconds=10):
        child = subprocess.Popen([sys.executable, "-c", f"import time; time.sleep({seconds})"],
                                 start_new_session=True)
        self.processes.append(child)
        return child

    def foreign_holder(self):
        code = ("import fcntl,select,sys; f=open(sys.argv[1], 'a+'); "
                "fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB); "
                "print('held',flush=True); select.select([sys.stdin],[],[],10)")
        process = subprocess.Popen([sys.executable, "-c", code, str(self.lock)],
                                   start_new_session=True, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True)
        self.processes.append(process)
        # Readiness uses a bounded kernel wait rather than an unbounded readline.
        self.assertTrue(select.select([process.stdout], [], [], 3)[0])
        self.assertEqual(process.stdout.readline().strip(), "held")
        return process

    def release_holder(self, process):
        process.stdin.write("release\n")
        process.stdin.flush()
        process.stdin.close()
        process.wait(timeout=3)

    def test_two_queued_jobs_run_in_submission_order_without_overlap(self):
        events = self.root / "events"
        def program(name):
            return ("import time; "
                    f"f=open({str(events)!r},'a',buffering=1); "
                    f"f.write('{name} start '+str(time.monotonic())+'\\n'); time.sleep(.25); "
                    f"f.write('{name} end '+str(time.monotonic())+'\\n')")
        holder = self.foreign_holder()
        first_args = self.job_args("first", program("first"))
        first_args[0] = "submit"
        second_args = self.job_args("second", program("second"))
        second_args[0] = "submit"
        self.assertEqual(self.invoke(first_args).returncode, 0)
        self.assertEqual(self.invoke(second_args).returncode, 0)
        self.await_job("second", lambda j: any("queued behind" in r for r in j["reasons"]))
        self.release_holder(holder)
        self.assertEqual(self.invoke(self.cli("wait", "first", ["--max-wait", "6"])).returncode, 0)
        self.assertEqual(self.invoke(self.cli("wait", "second", ["--max-wait", "6"])).returncode, 0)
        rows = [row.split() for row in events.read_text().splitlines()]
        self.assertEqual([row[:2] for row in rows], [["first", "start"], ["first", "end"],
                                                    ["second", "start"], ["second", "end"]])
        self.assertLessEqual(float(rows[1][2]), float(rows[2][2]))

    def test_foreign_lock_holder_waits_then_admits(self):
        holder = self.foreign_holder()
        runner = self.launch(self.job_args("foreign"))
        self.await_job("foreign", lambda j: j["reasons"] == ["shared QA lock held by another holder"])
        self.assertIsNone(holder.poll())
        self.release_holder(holder)
        self.assertEqual(self.finish(runner, "foreign", 0)["status"], "succeeded")

    def test_foreign_lock_deadline_leaves_holder_untouched(self):
        holder = self.foreign_holder()
        runner = self.launch(self.job_args("deadline", deadline=.3))
        result = self.finish(runner, "deadline", 75)
        self.assertEqual(result["status"], "admission_timeout")
        self.assertEqual(result["reasons"], ["shared QA lock held by another holder"])
        self.assertIsNone(holder.poll())
        with self.lock.open("a+") as lock:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.release_holder(holder)

    def test_normal_exit_signals_group_only_before_reaping_leader(self):
        events = self.root / "process-events"
        bootstrap = BOOTSTRAP.split("sys.exit")[0] + f"\nEVENTS = {str(events)!r}\n" + '''
OriginalPopen = q.subprocess.Popen
original_killpg = q.os.killpg
reaped = set()
def record(kind, pid):
    with open(EVENTS, 'a') as output:
        output.write(q.json.dumps([kind, pid]) + '\\n')
class ObservedPopen(OriginalPopen):
    def wait(self, *args, **kwargs):
        code = super().wait(*args, **kwargs)
        reaped.add(self.pid)
        record('wait', self.pid)
        return code
    def poll(self):
        code = super().poll()
        if code is not None:
            reaped.add(self.pid)
        record('poll', self.pid)
        return code
def observed_killpg(pgid, signum):
    if pgid in reaped:
        raise AssertionError('group signaled after leader reap')
    record('signal', pgid)
    return original_killpg(pgid, signum)
q.subprocess.Popen = ObservedPopen
q.os.killpg = observed_killpg
sys.exit(q.main(sys.argv[2:]))
'''
        runner = self.launch(self.job_args("pinned"), bootstrap)
        result = self.finish(runner, "pinned", 0)
        roles = [kind for kind, pid in map(json.loads, events.read_text().splitlines())
                 if pid == result["childPgid"]]
        self.assertIn("signal", roles)
        self.assertNotIn("poll", roles)
        self.assertEqual(roles[-1], "wait")
        self.assertEqual(roles.count("wait"), 1)
        self.assert_lock_free()

    def test_cancel_between_payload_spawn_and_assignment_cleans_payload(self):
        spawned = self.root / "spawned-pgid"
        bootstrap = BOOTSTRAP.split("sys.exit")[0] + f"\nSPAWNED = {str(spawned)!r}\n" + '''
original = q.subprocess.Popen
def interrupted_spawn(argv, *args, **kwargs):
    child = original(argv, *args, **kwargs)
    if 'spawn-token' in ' '.join(argv):
        with open(SPAWNED, 'w') as output:
            output.write(str(child.pid))
        q.signal.raise_signal(q.signal.SIGTERM)
    return child
q.subprocess.Popen = interrupted_spawn
sys.exit(q.main(sys.argv[2:]))
'''
        runner = self.launch(self.job_args("spawn-cancel", "import time; token='spawn-token'; time.sleep(10)"), bootstrap)
        try:
            result = self.finish(runner, "spawn-cancel", 130)
            self.assertEqual(result["status"], "cancelled")
            self.assertEqual(result["childPgid"], int(spawned.read_text()))
            self.assertFalse(qa.group_has_members(result["childPgid"]))
            self.assert_lock_free()
        finally:
            if spawned.exists():
                pgid = int(spawned.read_text())
                if qa.group_has_members(pgid):
                    qa.signal_owned_group(pgid, signal.SIGKILL)

    def test_submit_cancel_at_spawn_keeps_handoff_owned_by_runner(self):
        bootstrap = BOOTSTRAP.split("sys.exit")[0] + '''
original = q.subprocess.Popen
def interrupted_spawn(argv, *args, **kwargs):
    runner = original(argv, *args, **kwargs)
    if 'q.resume' in ' '.join(argv):
        q.signal.raise_signal(q.signal.SIGTERM)
    return runner
q.subprocess.Popen = interrupted_spawn
sys.exit(q.main(sys.argv[2:]))
'''
        args = self.job_args("submit-cancel")
        args[0] = "submit"
        submitter = self.launch(args, bootstrap)
        self.finish(submitter, "submit-cancel", 130)
        result = self.invoke(self.cli("wait", "submit-cancel", ["--max-wait", "6"]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "succeeded")
        self.assert_lock_free()

    def test_blocked_submit_receipt_does_not_hold_finished_jobs_liveness(self):
        reader, writer = os.pipe()
        try:
            os.set_blocking(writer, False)
            for _ in range(256):
                try:
                    os.write(writer, b"x" * 4096)
                except BlockingIOError:
                    break
            else:
                self.fail("test pipe did not fill within 1 MiB")
            os.set_blocking(writer, True)
            args = self.job_args("blocked-receipt")
            args[0] = "submit"
            submitter = subprocess.Popen([sys.executable, str(SCRIPT), *args], env=self.env,
                                         start_new_session=True, stdout=writer, stderr=subprocess.PIPE, text=True)
            self.processes.append(submitter)
            os.close(writer)
            writer = None
            self.await_job("blocked-receipt", lambda j: j["status"] in qa.TERMINAL)
            result = self.invoke(self.cli("wait", "blocked-receipt", ["--max-wait", "1"]))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(submitter.poll())
            with (self.state / "jobs/blocked-receipt/live.lock").open("r") as live:
                fcntl.flock(live, fcntl.LOCK_SH | fcntl.LOCK_NB)
            submitter.terminate()
            submitter.wait(timeout=3)
        finally:
            if writer is not None:
                os.close(writer)
            os.close(reader)

    def test_timeout_kills_descendant_ignoring_sigterm_and_releases_lock(self):
        program = """import os, signal, time
if os.fork() == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print(os.getpid(), flush=True)
time.sleep(10)
"""
        runner = self.launch(self.job_args("timeout", program, timeout=.4))
        result = self.finish(runner, "timeout", 124)
        self.assertEqual(result["status"], "timed_out")
        self.assertFalse(qa.group_has_members(result["childPgid"]))
        self.assert_lock_free()

    def test_cancel_running_cleans_group_and_releases_lock(self):
        runner = self.launch(self.job_args("cancel-run", "import time; time.sleep(10)"))
        self.await_job("cancel-run", lambda j: j["status"] == "running")
        cancel = self.invoke(self.cli("cancel", "cancel-run"))
        self.assertEqual(cancel.returncode, 0, cancel.stderr)
        result = self.finish(runner, "cancel-run", 130)
        self.assertEqual(result["status"], "cancelled")
        self.assertFalse(qa.group_has_members(result["childPgid"]))
        self.assert_lock_free()

    def test_cancel_queued_never_starts_child(self):
        holder = self.foreign_holder()
        first = self.launch(self.job_args("head"))
        self.await_job("head", lambda j: bool(j["reasons"]))
        runner = self.launch(self.job_args("cancel-queue"))
        self.await_job("cancel-queue", lambda j: any("queued behind" in r for r in j["reasons"]))
        cancel = self.invoke(self.cli("cancel", "cancel-queue"))
        self.assertEqual(cancel.returncode, 0, cancel.stderr)
        result = self.finish(runner, "cancel-queue", 130)
        self.assertEqual(result["status"], "cancelled")
        self.assertIsNone(result["childPgid"])
        self.release_holder(holder)
        self.finish(first, "head", 0)
        self.assert_lock_free()

    def test_stale_status_wait_cancel_and_later_admission(self):
        runner = self.launch(self.job_args("stale", "import time; time.sleep(10)"))
        job = self.await_job("stale", lambda j: j["status"] == "running")
        runner.kill()
        runner.wait(timeout=3)
        status = self.invoke(self.cli("status", "stale"))
        self.assertTrue(json.loads(status.stdout)["stale"])
        self.assertTrue(json.loads(status.stdout)["orphanGroupExists"])
        self.assertTrue(json.loads(status.stdout)["orphanGroupHasLiveMembers"])
        self.assertEqual(self.invoke(self.cli("wait", "stale", ["--max-wait", "1"])).returncode, 4)
        with patch.object(qa.os, "kill") as send:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(qa.cancel_job(self.state / "jobs/stale"), 4)
            send.assert_not_called()
        self.assertTrue(qa.group_has_members(job["childPgid"]))
        next_runner = self.launch(self.job_args("later"))
        self.finish(next_runner, "later", 0)
        self.assert_lock_free()

    def test_boot_failure_is_error_without_shutdown(self):
        self.configure(bootCode=9)
        runner = self.launch(self.job_args("boot-fail", kind="simulator", device="ours"))
        result = self.finish(runner, "boot-fail", 125)
        self.assertEqual(result["status"], "error")
        self.assertIn("boot ours exited 9", result["error"])
        self.assertFalse(result["bootedByJob"])
        self.assertFalse(any(row[1] == "shutdown" for row in self.calls()))
        self.assert_lock_free()

    def test_boot_timeout_reports_fresh_device_state_without_shutdown(self):
        self.configure(bootSleep=2, bootState="Booting")
        bootstrap = BOOTSTRAP.replace("sys.exit(q.main", "q.BOOT_TIMEOUT_SECONDS=1; sys.exit(q.main")
        runner = self.launch(self.job_args("boot-timeout", kind="simulator", device="ours"), bootstrap)
        result = self.finish(runner, "boot-timeout", 125)
        self.assertEqual(result["status"], "error")
        self.assertIn("boot of ours did not finish in 1 s; device is Booting", result["error"])
        self.assertIn("cannot prove it booted it", result["error"])
        self.assertFalse(result["bootedByJob"])
        self.assertIsNone(result["childPgid"])
        self.assertEqual(sum(row[1] == "list" for row in self.calls()), 2)
        self.assertFalse(any(row[1] in ("shutdown", "bootstatus") for row in self.calls()))
        self.assert_lock_free()

    def test_cancel_during_boot_persists_ownership_before_shutdown(self):
        self.configure(bootSleep=.4, bootState="Booting")
        runner = self.launch(self.job_args("boot-cancel", kind="simulator", device="ours"))
        self.await_job("boot-cancel", lambda j: any(row[1] == "boot" for row in self.calls()))
        os.kill(runner.pid, signal.SIGTERM)
        result = self.finish(runner, "boot-cancel", 130)
        self.assertEqual(result["status"], "cancelled")
        self.assertTrue(result["bootedByJob"])
        self.assertIsNone(result["childPgid"])
        self.assertEqual([row for row in self.calls() if row[1] == "shutdown"], [["simctl", "shutdown", "ours"]])
        self.assertFalse(any(row[1] == "bootstatus" for row in self.calls()))
        self.assert_lock_free()

    def test_child_signal_maps_to_128_plus_signal_for_run_and_wait(self):
        runner = self.launch(self.job_args("signal-exit", "import os,signal; os.kill(os.getpid(), signal.SIGTERM)"))
        result = self.finish(runner, "signal-exit", 128 + signal.SIGTERM)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["exitCode"], -signal.SIGTERM)
        self.assertEqual(result["signal"], signal.SIGTERM)
        waited = self.invoke(self.cli("wait", "signal-exit", ["--max-wait", "1"]))
        self.assertEqual(waited.returncode, 128 + signal.SIGTERM)
        self.assertEqual(json.loads(waited.stdout)["exitCode"], -signal.SIGTERM)
        self.assert_lock_free()

    def test_hangup_cancels_and_repeated_signals_do_not_interrupt_cleanup(self):
        program = ("import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                   "print('ready',flush=True); time.sleep(10)")
        runner = self.launch(self.job_args("hangup", program))
        job = self.await_job("hangup", lambda j: j["status"] == "running"
                             and "ready" in Path(j["logs"]["output"]).read_text())
        os.kill(runner.pid, signal.SIGHUP)
        time.sleep(.03)
        os.kill(runner.pid, signal.SIGTERM)
        os.kill(runner.pid, signal.SIGINT)
        result = self.finish(runner, "hangup", 130)
        self.assertEqual(result["status"], "cancelled")
        self.assertEqual(result["signal"], signal.SIGHUP)
        self.assertNotIn("Traceback", Path(result["logs"]["runner"]).read_text())
        self.assertFalse(qa.group_has_members(job["childPgid"]))
        self.assert_lock_free()

    def test_memory_unreadable_is_error(self):
        self.configure(memory="unparseable")
        runner = self.launch(self.job_args("memory"))
        result = self.finish(runner, "memory", 125)
        self.assertEqual(result["status"], "error")
        self.assertIn("cannot read memory", result["error"])
        self.assert_lock_free()

    def test_package_never_invokes_simctl_with_booted_device(self):
        self.configure(devices=[dict(udid="ours", state="Booted")])
        runner = self.launch(self.job_args("package"))
        result = self.finish(runner, "package", 0)
        self.assertEqual(self.calls(), [])
        self.assertNotIn("shared QA lock held by another holder", Path(result["logs"]["runner"]).read_text())

    def test_simulator_shuts_down_only_device_booted_by_job(self):
        runner = self.launch(self.job_args("sim", kind="simulator", device="ours"))
        result = self.finish(runner, "sim", 0)
        self.assertTrue(result["bootedByJob"])
        self.assertEqual([row for row in self.calls() if row[1] == "shutdown"], [["simctl", "shutdown", "ours"]])
        self.assertEqual(result["shutdownExitCode"], 0)

    def test_busy_device_times_out_without_boot_or_shutdown(self):
        self.configure(devices=[dict(udid="ours", state="Booted")])
        runner = self.launch(self.job_args("busy", kind="simulator", device="ours", deadline=2))
        result = self.finish(runner, "busy", 75)
        self.assertIn("device ours is Booted", result["reasons"])
        self.assertTrue(all(row[1] == "list" for row in self.calls()))

    def test_missing_device_is_error_without_boot(self):
        self.configure(devices=[])
        runner = self.launch(self.job_args("missing", kind="simulator", device="ours"))
        result = self.finish(runner, "missing", 125)
        self.assertEqual(result["error"], "device ours does not exist; no device is created")
        self.assertTrue(all(row[1] == "list" for row in self.calls()))

    def test_heavy_process_exits_naturally_before_admission(self):
        sleeper = self.sleeper(1.2)
        self.configure(processes=[sleeper.pid])
        runner = self.launch(self.job_args("heavy"))
        self.await_job("heavy", lambda j: any("heavy process" in r for r in j["reasons"]))
        # The fake lister must omit the exited process, just as real ps does.
        sleeper.wait(timeout=3)
        self.configure(processes=[])
        result = self.finish(runner, "heavy", 0)
        self.assertEqual(sleeper.returncode, 0)
        self.assertEqual(result["status"], "succeeded")

    def test_heavy_process_deadline_leaves_process_alive(self):
        sleeper = self.sleeper()
        self.configure(processes=[sleeper.pid])
        runner = self.launch(self.job_args("heavy-timeout", deadline=2))
        result = self.finish(runner, "heavy-timeout", 75)
        self.assertTrue(any("heavy process" in r for r in result["reasons"]))
        self.assertIsNone(sleeper.poll())

    def test_submit_wait_returns_child_exit_code(self):
        args = self.job_args("submitted", "import sys,time; time.sleep(.2); sys.exit(7)")
        args[0] = "submit"
        submit = self.invoke(args)
        self.assertEqual(submit.returncode, 0, submit.stderr)
        receipt = json.loads(submit.stdout)
        self.assertEqual(receipt["jobId"], "submitted")
        result = self.invoke(self.cli("wait", "submitted", ["--max-wait", "6"]))
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "failed")
        self.assert_lock_free()

    def test_submit_wait_max_wait_does_not_affect_job(self):
        args = self.job_args("short-wait", "import time; time.sleep(.5)")
        args[0] = "submit"
        self.assertEqual(self.invoke(args).returncode, 0)
        result = self.invoke(self.cli("wait", "short-wait", ["--max-wait", ".05"]))
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertTrue(json.loads(result.stdout)["live"])
        final = self.invoke(self.cli("wait", "short-wait", ["--max-wait", "6"]))
        self.assertEqual(final.returncode, 0, final.stderr)
        self.assertEqual(json.loads(final.stdout)["status"], "succeeded")

    def test_shutdown_failure_records_cleanup_failed_and_releases_lock(self):
        self.configure(shutdownCode=8)
        runner = self.launch(self.job_args("shutdown-fail", kind="simulator", device="ours"))
        result = self.finish(runner, "shutdown-fail", 125)
        self.assertEqual(result["status"], "cleanup_failed")
        self.assertEqual(result["shutdownExitCode"], 8)
        self.assertIn("shutdown ours exited 8", result["cleanupError"])
        self.assert_lock_free()

    def test_bootstatus_failure_still_shuts_down_owned_device(self):
        self.configure(bootstatusCode=6)
        runner = self.launch(self.job_args("bootstatus-fail", kind="simulator", device="ours"))
        result = self.finish(runner, "bootstatus-fail", 125)
        self.assertEqual(result["status"], "error")
        self.assertEqual([row for row in self.calls() if row[1] == "shutdown"], [["simctl", "shutdown", "ours"]])

    def test_unknown_job_duplicate_id_and_cli_validation(self):
        unknown = self.invoke(self.cli("wait", "unknown"))
        self.assertEqual(unknown.returncode, 2)
        self.assertIn("unknown job unknown", unknown.stderr)
        runner = self.launch(self.job_args("unique"))
        self.finish(runner, "unique", 0)
        old = (self.state / "jobs/unique/job.json").read_bytes()
        self.assertEqual(self.invoke(self.job_args("unique")).returncode, 2)
        self.assertEqual((self.state / "jobs/unique/job.json").read_bytes(), old)
        for args in (self.job_args("bad", device="ours"),
                     self.job_args("bad", kind="simulator"),
                     self.job_args("bad", deadline=float("nan"))):
            self.assertEqual(self.invoke(args).returncode, 2)


class PureTests(unittest.TestCase):
    def test_agent_device_classification_both_only_testing_forms(self):
        for flag in (f"-only-testing {qa.SERVICE_TEST}", f"-only-testing:{qa.SERVICE_TEST}"):
            process = dict(comm="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
                           args=("/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild "
                                 f"test-without-building {flag} -destination "
                                 "platform=iOS Simulator,id=A4EE0B20-1654-4B67-B54E-D071DA1E9601"))
            for kind in ("package", "render"):
                self.assertEqual(qa.classify_process(process, kind), "ignored")
            self.assertEqual(qa.classify_process(process, "simulator", "A4EE0B20-1654-4B67-B54E-D071DA1E9601"), "blocker")
            self.assertEqual(qa.classify_process(process, "simulator", "other"), "ignored")

    def test_xcodebuild_without_all_markers_blocks(self):
        for args in ("xcodebuild", f"xcodebuild -only-testing {qa.SERVICE_TEST}",
                     "xcodebuild test-without-building -only-testing WrongTest",
                     f"xcodebuild test-without-building echo {qa.SERVICE_TEST}"):
            self.assertEqual(qa.classify_process(dict(comm="xcodebuild", args=args), "package"), "blocker")
        self.assertEqual(qa.classify_process(dict(comm="swift-build", args="", stat="Z"), "package"), "irrelevant")
        self.assertEqual(qa.classify_process(dict(comm="/Applications/T3 Code App", args="blender"), "package"), "irrelevant")

    def test_memory_and_disk_threshold_boundaries(self):
        for pressure in (1, 2):
            self.assertEqual(qa.resource_blockers(pressure, 35, 5 * 1024**3), [])
        self.assertTrue(qa.resource_blockers(4, 80, 6 * 1024**3))
        self.assertTrue(qa.resource_blockers(1, 34, 6 * 1024**3))
        self.assertTrue(qa.resource_blockers(1, 35, 5 * 1024**3 - 1))

    def test_eperm_zombie_and_uncertain_owned_group(self):
        with patch.object(qa.os, "killpg", side_effect=PermissionError), \
             patch.object(qa, "group_has_members", return_value=False):
            self.assertFalse(qa.signal_owned_group(123, signal.SIGTERM))
        with patch.object(qa.os, "killpg", side_effect=PermissionError), \
             patch.object(qa, "group_has_members", return_value=True):
            with self.assertRaisesRegex(RuntimeError, "live members remain"):
                qa.signal_owned_group(123, signal.SIGTERM)

    def test_cancel_pid_start_mismatch_never_signals(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "live.lock").touch()
            qa.write_job(directory, dict(runnerPid=123, runnerStart="old"))
            with (directory / "live.lock").open("a+") as live:
                fcntl.flock(live, fcntl.LOCK_EX)
                with patch.object(qa, "runner_start", return_value="new"), \
                     patch.object(qa.os, "kill") as send, contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(qa.cancel_job(directory), 4)
                    send.assert_not_called()

    def test_release_ticket_is_idempotent_and_records_unlink_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "ticket"
            ticket = path.open("a+")
            fcntl.flock(ticket, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(Path, "unlink", side_effect=OSError("unlink refused")):
                errors = qa.release_ticket(path, ticket)
                self.assertIn("unlink refused", "; ".join(errors))
                self.assertTrue(ticket.closed)
                self.assertIn("unlink refused", "; ".join(qa.release_ticket(path, ticket)))
            self.assertEqual(qa.release_ticket(path, ticket), [])
            self.assertEqual(qa.release_ticket(path, None), [])
            self.assertFalse(path.exists())

    def test_cleanup_hold_keeps_lock_until_group_gone_or_deadline(self):
        for members_remain in (False, True):
            with self.subTest(members_remain=members_remain), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                args = Mock(state_dir=root / "state", job_id="hold", kind="package", argv=["unused"],
                            cwd=root, device=None, admission_deadline=3, timeout=1)
                directory, live, job = qa.create_job(args)
                clock = [0]
                lock_path = root / "lock"
                def sleep(seconds):
                    self.assertEqual(qa.read_job(directory)["status"], "cleanup_failed")
                    with lock_path.open("a+") as probe:
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    clock[0] += seconds
                def members(pgid):
                    return members_remain or clock[0] < 1
                with patch.object(qa.time, "monotonic", side_effect=lambda: clock[0]), \
                     patch.object(qa.time, "sleep", side_effect=sleep), \
                     patch.object(qa, "CLEANUP_HOLD_SECONDS", 2), \
                     patch.object(qa, "runner_start", return_value="test identity"), \
                     patch.object(qa, "sense_memory", return_value=(1, 80)), \
                     patch.object(qa, "sense_disk", return_value=10 * 1024**3), \
                     patch.object(qa, "list_processes", return_value=[]), \
                     patch.object(qa, "wait_child_exit", return_value=True), \
                     patch.object(qa, "group_has_members", side_effect=members), \
                     patch.object(qa.subprocess, "Popen", return_value=Mock(pid=123, wait=Mock(return_value=0))) as spawn, \
                     patch.object(qa, "stop_owned_command", side_effect=RuntimeError("members survive SIGKILL")):
                    self.assertEqual(qa.run_job(directory, live, job, lock_path, echo=False), 125)
                result = qa.read_job(directory)
                self.assertEqual(result["status"], "cleanup_failed")
                expected = "live members remained" if members_remain else "no live members remained"
                self.assertIn(expected, result["cleanupError"])
                self.assertEqual(clock[0], 2 if members_remain else 1)
                self.assertNotIn("pass_fds", spawn.call_args.kwargs)
                with lock_path.open("a+") as probe:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_finalizer_failures_do_not_skip_other_release_steps(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = Mock(state_dir=root / "state", job_id="finalizer", kind="package", argv=["unused"],
                        cwd=root, device=None, admission_deadline=3, timeout=1)
            directory, live, job = qa.create_job(args)
            lock_path = root / "lock"
            events = []
            original_open = Path.open
            original_flock = qa.fcntl.flock
            original_signal = qa.signal.signal
            original_release = qa.release_ticket
            previous_signals = {sig: qa.signal.getsignal(sig) for sig in qa.RUNNER_SIGNALS}
            class CloseSpy:
                def __init__(self, stream, label, fail=False):
                    self.stream, self.label, self.fail = stream, label, fail
                def __getattr__(self, name):
                    return getattr(self.stream, name)
                def close(self):
                    events.append(self.label)
                    self.stream.close()
                    if self.fail:
                        raise OSError(self.label + " failed")
            def opened(path, *args, **kwargs):
                stream = original_open(path, *args, **kwargs)
                if path == lock_path:
                    return CloseSpy(stream, "close global")
                if path == directory / "runner.log":
                    return CloseSpy(stream, "close log", fail=True)
                return stream
            def flock(fd, operation):
                if getattr(fd, "name", None) == str(lock_path) and operation == fcntl.LOCK_UN:
                    events.append("unlock global")
                    raise OSError("unlock global failed")
                return original_flock(fd, operation)
            def restore(sig, handler):
                value = original_signal(sig, handler)
                if sig in previous_signals and handler == previous_signals[sig]:
                    events.append(f"restore {sig}")
                    if sig == signal.SIGTERM:
                        raise OSError("restore SIGTERM failed")
                return value
            releases = [0]
            def release(path, ticket):
                releases[0] += 1
                if releases[0] == 2:
                    events.append("release ticket")
                    raise OSError("release ticket failed")
                return original_release(path, ticket)
            with patch.object(Path, "open", new=opened), \
                 patch.object(qa.fcntl, "flock", side_effect=flock), \
                 patch.object(qa.signal, "signal", side_effect=restore), \
                 patch.object(qa, "release_ticket", side_effect=release), \
                 patch.object(qa, "runner_start", return_value="test identity"), \
                 patch.object(qa, "sense_memory", return_value=(1, 80)), \
                 patch.object(qa, "sense_disk", return_value=10 * 1024**3), \
                 patch.object(qa, "list_processes", return_value=[]), \
                 patch.object(qa, "wait_child_exit", return_value=True), \
                 patch.object(qa.subprocess, "Popen", return_value=Mock(pid=123)), \
                 patch.object(qa, "stop_owned_command", return_value=0):
                self.assertEqual(qa.run_job(directory, CloseSpy(live, "close live", fail=True), job,
                                            lock_path, echo=False), 125)
            result = qa.read_job(directory)
            self.assertEqual(result["status"], "cleanup_failed")
            for label in ("unlock global", "release ticket", "close log", "close live", "restore SIGTERM"):
                self.assertIn(label + " failed", result["cleanupError"])
            for label in ("close global", f"restore {signal.SIGINT}", f"restore {signal.SIGHUP}"):
                self.assertIn(label, events)
            self.assertTrue(live.closed)
            with lock_path.open("a+") as probe:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_simulator_boot_has_a_separate_clock_from_admission(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = Mock(state_dir=root / "state", job_id="boot-clock", kind="simulator", argv=["unused"],
                        cwd=root, device="ours", admission_deadline=1, timeout=1)
            directory, live, job = qa.create_job(args)
            clock = [0]
            def fake_simctl(operation, device, **kwargs):
                if operation in ("boot", "bootstatus"):
                    self.assertEqual(kwargs["timeout"], qa.BOOT_TIMEOUT_SECONDS)
                    clock[0] += 2
                return Mock(returncode=0)
            with patch.object(qa.time, "monotonic", side_effect=lambda: clock[0]), \
                 patch.object(qa, "runner_start", return_value="test identity"), \
                 patch.object(qa, "sense_memory", return_value=(1, 80)), \
                 patch.object(qa, "sense_disk", return_value=10 * 1024**3), \
                 patch.object(qa, "list_processes", return_value=[]), \
                 patch.object(qa, "sense_devices", return_value=[dict(udid="ours", state="Shutdown")]), \
                 patch.object(qa, "simctl", side_effect=fake_simctl) as simctl, \
                 patch.object(qa, "wait_child_exit", return_value=True), \
                 patch.object(qa.subprocess, "Popen", return_value=Mock(pid=123, wait=Mock(return_value=0))) as spawn, \
                 patch.object(qa, "stop_owned_command", return_value=0):
                self.assertEqual(qa.run_job(directory, live, job, root / "lock", echo=False, deadline=1), 0)
            self.assertTrue(spawn.called)
            self.assertEqual([call.args[0] for call in simctl.call_args_list], ["boot", "bootstatus", "shutdown"])
            self.assertEqual(qa.read_job(directory)["status"], "succeeded")

    def test_cleanup_error_still_shutdowns_owned_device_and_releases_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = Mock(state_dir=root / "state", job_id="cleanup", kind="simulator", argv=["unused"],
                        cwd=root, device="ours", admission_deadline=3, timeout=1)
            directory, live, job = qa.create_job(args)
            lock_path = root / "lock"
            with patch.object(qa, "runner_start", return_value="test identity"), \
                 patch.object(qa, "sense_memory", return_value=(1, 80)), \
                 patch.object(qa, "sense_disk", return_value=10 * 1024**3), \
                 patch.object(qa, "list_processes", return_value=[]), \
                 patch.object(qa, "sense_devices", return_value=[dict(udid="ours", state="Shutdown")]), \
                 patch.object(qa, "simctl", return_value=Mock(returncode=0)) as simctl, \
                 patch.object(qa, "wait_child_exit", return_value=True), \
                 patch.object(qa, "group_has_members", return_value=False), \
                 patch.object(qa.subprocess, "Popen", return_value=Mock(pid=123, wait=Mock(return_value=0))), \
                 patch.object(qa, "stop_owned_command", side_effect=RuntimeError("cannot confirm owned group gone")):
                self.assertEqual(qa.run_job(directory, live, job, lock_path, echo=False), 125)
            result = qa.read_job(directory)
            self.assertEqual(result["status"], "cleanup_failed")
            self.assertIn("cannot confirm", result["cleanupError"])
            self.assertEqual(simctl.call_args.args, ("shutdown", "ours"))
            with lock_path.open("a+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)


if __name__ == "__main__":
    unittest.main()
