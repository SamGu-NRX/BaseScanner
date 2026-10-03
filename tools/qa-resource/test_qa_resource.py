import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import secrets
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
TEST_OWNER_PREFIX = f"QA_RESOURCE_TEST_{secrets.token_hex(16)}_"
qa.OWNER_ENV_PREFIX = TEST_OWNER_PREFIX

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
TEST_SETUP = '''import sys; sys.path.insert(0, sys.argv[1]); import qa_resource as q
q.OWNER_ENV_PREFIX = q.os.environ['QA_TEST_OWNER_PREFIX']
class TestPopen(q.subprocess.Popen):
    def __init__(self, args, *positional, **keywords):
        if (isinstance(args, (list, tuple)) and len(args) > 2 and args[1] == '-c'
                and args[2].startswith('import sys; sys.path.insert(0, sys.argv[1]); import qa_resource as q; sys.exit(q.resume(')):
            args = list(args)
            settings = ('q.OWNER_ENV_PREFIX=' + repr(q.OWNER_ENV_PREFIX) + '; '
                        'q.CLEANUP_GRACE_SECONDS=.2; q.RESAMPLE_SECONDS=.1; ')
            args[2] = args[2].replace('import qa_resource as q; ', 'import qa_resource as q; ' + settings)
        super().__init__(args, *positional, **keywords)
q.subprocess.Popen = TestPopen
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
                        QA_TEST_CONFIG=str(self.config_path), QA_TEST_OWNER_PREFIX=TEST_OWNER_PREFIX)
        self.processes = []
        self.detached = []
        self.escaped_targets = []

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
        for pid, start in self.escaped_targets:
            identity = qa.process_identity(pid, details=True)
            if identity and identity["start"] == start and not identity["stat"].startswith("Z"):
                os.kill(pid, signal.SIGKILL)  # Only an individually recorded test-spawned PID.
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
        process = subprocess.Popen([sys.executable, "-c", TEST_SETUP + bootstrap, str(SCRIPT.parent), *args],
                                   env=self.env, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(process)
        return process

    def invoke(self, args):
        result = subprocess.run([sys.executable, "-c", TEST_SETUP + BOOTSTRAP, str(SCRIPT.parent), *args], env=self.env,
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

    def await_path(self, path, seconds=5):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if path.exists():
                return
            time.sleep(.02)
        self.fail(f"test payload did not create {path}")

    def escaped_pid(self, path):
        self.await_path(path)
        pid = int(path.read_text())
        identity = qa.process_identity(pid, details=True)
        if identity is not None:
            self.escaped_targets.append((pid, identity["start"]))
        return pid

    def escape_program(self, files, ignores, parent_live=True, ancestry=False, parents_ignore=True):
        programs = []
        for path, ignore in zip(files, ignores):
            programs.append("import os,signal,time; from pathlib import Path; "
                            + ("signal.signal(signal.SIGTERM,signal.SIG_IGN); " if ignore else "")
                            + f"Path({str(path)!r}).write_text(str(os.getpid())); time.sleep(30)")
        middle = "import os,signal,subprocess,sys,time; from pathlib import Path\n"
        if ancestry and parents_ignore:
            middle += "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
        middle += "environment=dict(os.environ)\n"
        if ancestry:
            middle += f"environment={{k:v for k,v in environment.items() if not k.startswith({TEST_OWNER_PREFIX!r})}}\n"
        for code in programs:
            middle += f"subprocess.Popen([sys.executable,'-c',{code!r}], start_new_session=True,env=environment)\n"
        middle += (f"files={list(map(str, files))!r}\nend=time.monotonic()+4\n"
                   "while not all(Path(p).exists() for p in files):\n"
                   "    if time.monotonic()>=end: raise RuntimeError('grandchild startup deadline')\n"
                   "    time.sleep(.01)\n")
        if ancestry:
            middle += "time.sleep(30)\n"
        parent = ("import signal,subprocess,sys,time; from pathlib import Path\n"
                  + ("signal.signal(signal.SIGTERM,signal.SIG_IGN)\n" if ancestry and parents_ignore else "")
                  + f"middle=subprocess.Popen([sys.executable,'-c',{middle!r}])\n")
        if ancestry:
            parent += (f"files={list(map(str, files))!r}\nend=time.monotonic()+4\n"
                       "while not all(Path(p).exists() for p in files):\n"
                       "    if time.monotonic()>=end: raise RuntimeError('ancestry startup deadline')\n"
                       "    time.sleep(.01)\n")
        else:
            parent += "middle.wait(timeout=5)\n"
        parent += f"Path({str(self.root / 'parent-ready')!r}).touch()\n"
        if parent_live:
            parent += "time.sleep(30)\n"
        return parent

    def escaped_gone(self, pid):
        identity = qa.process_identity(pid, details=True)
        return identity is None or identity["stat"].startswith("Z")

    def assert_escaped_result(self, job, expected):
        records = {p["pid"]: p for p in job["escapedProcesses"]}
        self.assertEqual(set(records), set(expected))
        for pid, (proof, outcome) in expected.items():
            self.assertEqual(records[pid]["proof"], proof)
            self.assertEqual(records[pid]["outcome"], outcome)
            self.assertTrue(records[pid]["start"])
            self.assertTrue(records[pid]["comm"])
            self.assertTrue(self.escaped_gone(pid), records[pid])
        log = Path(job["logs"]["runner"]).read_text()
        self.assertIn('"escapedProcesses"', log)
        self.assert_lock_free()

    def test_cancel_reparented_session_descendants_and_preserve_sentinel(self):
        sentinel = self.sleeper(30)
        paths = [self.root / "normal", self.root / "ignores"]
        runner = self.launch(self.job_args("escape-cancel", self.escape_program(paths, [False, True]), timeout=10))
        self.await_path(self.root / "parent-ready")
        pids = [self.escaped_pid(p) for p in paths]
        for pid in pids:
            identity = qa.process_identity(pid, details=True)
            self.assertEqual(identity["ppid"], 1)
            self.assertEqual(identity["pgid"], pid)
        self.assertEqual(self.invoke(self.cli("cancel", "escape-cancel")).returncode, 0)
        result = self.finish(runner, "escape-cancel", 130)
        self.assert_escaped_result(result, {pids[0]: ("token", "terminated"), pids[1]: ("token", "killed")})
        self.assertIsNone(sentinel.poll())

    def test_timeout_kills_escaped_ignoring_descendant_not_sentinel(self):
        sentinel = self.sleeper(30)
        path = self.root / "escaped"
        runner = self.launch(self.job_args("escape-timeout", self.escape_program([path], [True]), timeout=.8))
        pid = self.escaped_pid(path)
        result = self.finish(runner, "escape-timeout", 124)
        self.assertEqual(result["status"], "timed_out")
        self.assert_escaped_result(result, {pid: ("token", "killed")})
        self.assertIsNone(sentinel.poll())

    def test_natural_exit_cleans_detached_helper_before_lock_release(self):
        path = self.root / "escaped"
        runner = self.launch(self.job_args("escape-natural", self.escape_program([path], [True], parent_live=False)))
        pid = self.escaped_pid(path)
        deadline = time.monotonic() + 6
        with self.lock.open("a+") as probe:
            while True:
                try:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self.assertTrue(self.escaped_gone(pid), "escaped helper lived past lock release")
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        self.fail("natural-exit cleanup did not release the test lock")
                    time.sleep(.01)
        result = self.finish(runner, "escape-natural", 0)
        self.assertEqual(result["status"], "succeeded")
        self.assert_escaped_result(result, {pid: ("token", "killed")})

    def test_tokenless_session_descendant_is_owned_by_live_ancestry(self):
        path = self.root / "ancestry"
        runner = self.launch(self.job_args("escape-ancestry", self.escape_program([path], [True], ancestry=True), timeout=10))
        self.await_path(self.root / "parent-ready")
        pid = self.escaped_pid(path)
        self.assertFalse(any(entry.startswith(TEST_OWNER_PREFIX) for entry in qa.process_env(pid)))
        self.assertNotEqual(qa.process_identity(pid, details=True)["ppid"], 1)
        self.assertEqual(self.invoke(self.cli("cancel", "escape-ancestry")).returncode, 0)
        result = self.finish(runner, "escape-ancestry", 130)
        self.assert_escaped_result(result, {pid: ("ancestry", "killed")})

    def test_ineffective_escaped_kill_records_retained_and_holds_lock(self):
        path = self.root / "retained"
        args = Mock(state_dir=self.state, job_id="retained", kind="package",
                    argv=[sys.executable, "-c", self.escape_program([path], [True], parent_live=False)],
                    cwd=self.root, device=None, admission_deadline=5, timeout=3)
        directory, live, job = qa.create_job(args)
        real_kill, real_sleep = os.kill, time.sleep
        held = []
        def ineffective(pid, sig):
            if path.exists() and pid == int(path.read_text()):
                return None
            return real_kill(pid, sig)
        def observe_hold(seconds):
            if qa.read_job(directory)["status"] == "cleanup_failed":
                with self.lock.open("a+") as probe:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                held.append(time.monotonic())
            real_sleep(seconds)
        with patch.object(qa, "sense_memory", return_value=(1, 80)), \
             patch.object(qa, "sense_disk", return_value=10 * 1024**3), \
             patch.object(qa, "list_processes", return_value=[]), \
             patch.object(qa, "owner_blockers", return_value=([], [])), \
             patch.object(qa, "CLEANUP_GRACE_SECONDS", .1), \
             patch.object(qa, "CLEANUP_CONFIRM_SECONDS", .1), \
             patch.object(qa, "CLEANUP_HOLD_SECONDS", .2), \
             patch.object(qa.os, "kill", side_effect=ineffective), \
             patch.object(qa.time, "sleep", side_effect=observe_hold):
            self.assertEqual(qa.run_job(directory, live, job, self.lock, echo=False), 125)
        pid = self.escaped_pid(path)
        result = qa.read_job(directory)
        self.assertEqual(result["status"], "cleanup_failed")
        self.assertTrue(held)
        self.assertIn(str(pid), result["cleanupError"])
        self.assertIn("hold expired", result["cleanupError"])
        record = result["escapedProcesses"][0]
        self.assertEqual(record["outcome"], "retained")
        for field in ("comm", "start"):
            self.assertIn(record[field], result["cleanupError"])
        self.assertFalse(self.escaped_gone(pid))
        self.assert_lock_free()

    def test_token_orphan_admission_deadline_never_signals_orphan(self):
        token = secrets.token_hex(16)
        orphan = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                  env=dict(self.env, **{TEST_OWNER_PREFIX + token: "older-job"}),
                                  start_new_session=True)
        self.processes.append(orphan)
        runner = self.launch(self.job_args("orphan-blocked", deadline=1))
        self.await_job("orphan-blocked", lambda j: any("owner token of job older-job" in r for r in j["reasons"]))
        result = self.finish(runner, "orphan-blocked", 75)
        self.assertEqual(result["status"], "admission_timeout")
        self.assertIsNone(orphan.poll())
        self.assertIsNone(result["childPgid"])
        self.assert_lock_free()

    def test_token_bearing_ancestor_is_excluded_when_runner_has_no_token(self):
        outer_name = TEST_OWNER_PREFIX + secrets.token_hex(16)
        self.env[outer_name] = "ancestor-job"
        path = self.root / "inherited"
        code = ("import os,json; from pathlib import Path; "
                f"Path({str(path)!r}).write_text(json.dumps({{k:v for k,v in os.environ.items() if k.startswith({TEST_OWNER_PREFIX!r})}}))")
        bootstrap = BOOTSTRAP.replace("sys.exit(q.main", f"q.os.environ.pop({outer_name!r}); sys.exit(q.main")
        argv = [sys.executable, "-c", TEST_SETUP + bootstrap, str(SCRIPT.parent), *self.job_args("nested", code)]
        parent = self.launch([], bootstrap=f"import subprocess,sys; sys.exit(subprocess.call({argv!r}))")
        output, error = parent.communicate(timeout=8)
        self.assertEqual(parent.returncode, 0, (output, error))
        result = self.job("nested")
        entries = json.loads(path.read_text())
        self.assertNotIn(outer_name, entries)
        self.assertEqual(entries[TEST_OWNER_PREFIX + result["ownerToken"]], "nested")
        self.assertEqual(len(entries), 1)
        self.assertEqual(result["status"], "succeeded")

    def test_old_metadata_without_ownership_fields_supports_status_wait_cancel(self):
        runner = self.launch(self.job_args("old-fields", "import time; time.sleep(30)", timeout=40))
        self.await_job("old-fields", lambda j: j["status"] == "running")
        directory = self.state / "jobs" / "old-fields"
        old = qa.read_job(directory)
        old.pop("ownerToken")
        old.pop("escapedProcesses")
        qa.write_job(directory, old)
        self.assertEqual(self.invoke(self.cli("status", "old-fields")).returncode, 0)
        self.assertEqual(self.invoke(self.cli("wait", "old-fields", ["--max-wait", ".1"])).returncode, 3)
        self.assertEqual(self.invoke(self.cli("cancel", "old-fields")).returncode, 0)
        self.finish(runner, "old-fields", 130)
        terminal = qa.read_job(directory)
        terminal.pop("ownerToken", None)
        terminal.pop("escapedProcesses", None)
        qa.write_job(directory, terminal)
        self.assertEqual(self.invoke(self.cli("wait", "old-fields", ["--max-wait", "1"])).returncode, 130)

    def test_tokenless_escape_survives_parent_term_but_not_durable_cleanup(self):
        sentinel = self.sleeper(30)
        path = self.root / "tokenless-normal-parents"
        code = self.escape_program([path], [True], ancestry=True, parents_ignore=False)
        runner = self.launch(self.job_args("durable-ancestry", code, timeout=10))
        self.await_path(self.root / "parent-ready")
        pid = self.escaped_pid(path)
        self.assertFalse(any(entry.startswith(TEST_OWNER_PREFIX) for entry in qa.process_env(pid)))
        self.assertEqual(self.invoke(self.cli("cancel", "durable-ancestry")).returncode, 0)
        result = self.finish(runner, "durable-ancestry", 130)
        self.assert_escaped_result(result, {pid: ("ancestry", "killed")})
        self.assertGreater(result["escapedProcesses"][0]["start_us"], 0)
        self.assertIsNone(sentinel.poll())

    def test_empty_argv_sleep_is_found_on_cancel_and_natural_exit(self):
        for natural in (False, True):
            with self.subTest(natural=natural):
                path = self.root / f"empty-argv-{natural}"
                code = ("import os,subprocess,time; from pathlib import Path; "
                        f"env={{k:v for k,v in os.environ.items() if k.startswith({TEST_OWNER_PREFIX!r})}}; "
                        "child=subprocess.Popen(['','30'], executable='/bin/sleep',env=env,start_new_session=True); "
                        f"Path({str(path)!r}).write_text(str(child.pid)); "
                        + ("time.sleep(30)" if not natural else "pass"))
                name = f"empty-argv-{natural}"
                runner = self.launch(self.job_args(name, code, timeout=10))
                pid = self.escaped_pid(path)
                if not natural:
                    entry = qa.owner_entry(self.job(name))
                    self.assertIn(entry, qa.process_env(pid))
                    self.assertEqual(self.invoke(self.cli("cancel", name)).returncode, 0)
                result = self.finish(runner, name, 0 if natural else 130)
                self.assert_escaped_result(result, {pid: ("token", "terminated")})

    def test_failed_discovery_still_term_and_kills_pinned_group_and_holds_lock(self):
        code = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)"
        args = Mock(state_dir=self.state, job_id="snapshot-failure", kind="package",
                    argv=[sys.executable, "-c", code], cwd=self.root, device=None,
                    admission_deadline=5, timeout=.2)
        directory, live, job = qa.create_job(args)
        real_killpg, real_sleep = os.killpg, time.sleep
        held = []
        def observe(seconds):
            if qa.read_job(directory)["status"] == "cleanup_failed":
                with self.lock.open("a+") as probe:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                held.append(True)
            real_sleep(seconds)
        with patch.object(qa, "sense_memory", return_value=(1, 80)), \
             patch.object(qa, "sense_disk", return_value=10 * 1024**3), \
             patch.object(qa, "list_processes", return_value=[]), \
             patch.object(qa, "owner_blockers", return_value=([], [])), \
             patch.object(qa, "owned_processes", side_effect=RuntimeError("injected ps snapshot failure")), \
             patch.object(qa, "CLEANUP_GRACE_SECONDS", .1), \
             patch.object(qa, "CLEANUP_CONFIRM_SECONDS", .1), \
             patch.object(qa, "CLEANUP_HOLD_SECONDS", .2), \
             patch.object(qa.os, "killpg", wraps=real_killpg) as killpg, \
             patch.object(qa.time, "sleep", side_effect=observe):
            self.assertEqual(qa.run_job(directory, live, job, self.lock, echo=False), 125)
        result = qa.read_job(directory)
        self.assertEqual(result["status"], "cleanup_failed")
        self.assertIn("injected ps snapshot failure", result["cleanupError"])
        self.assertTrue(held)
        self.assertEqual([call.args for call in killpg.call_args_list],
                         [(result["childPgid"], signal.SIGTERM), (result["childPgid"], signal.SIGKILL)])
        self.assertFalse(qa.group_has_members(result["childPgid"]))
        self.assert_lock_free()

    def test_run_and_submit_refuse_inherited_owner_before_creating_job(self):
        self.env[TEST_OWNER_PREFIX + secrets.token_hex(16)] = "outer-job"
        for command in ("run", "submit"):
            args = self.job_args("nested-refused")
            args[0] = command
            result = self.invoke(args)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("nested qa-resource jobs are not supported: this process belongs to job outer-job",
                          result.stderr)
            self.assertFalse(self.state.exists())
            self.assertFalse(self.lock.exists())

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
        args = self.job_args("submit-cancel", "import time; time.sleep(30)", timeout=40)
        args[0] = "submit"
        submitter = self.launch(args, bootstrap)
        output, error = submitter.communicate(timeout=8)
        self.assertEqual(submitter.returncode, 130, error)
        # An interrupted submit still reports the job it started, and cancels it.
        receipt = json.loads(output)
        self.assertEqual(receipt["jobId"], "submit-cancel")
        self.assertTrue(receipt["cancelRequested"])
        result = self.invoke(self.cli("wait", "submit-cancel", ["--max-wait", "6"]))
        self.assertEqual(result.returncode, 130, result.stderr)
        job = json.loads(result.stdout)
        self.assertEqual(job["status"], "cancelled")
        # Usually the cancel lands before admission; if the payload did start, it must be gone.
        if job["childPgid"] is not None:
            self.assertFalse(qa.group_has_members(job["childPgid"]))
        self.assert_lock_free()

    def test_cancel_during_runner_startup_is_queued_not_refused(self):
        # Delay the detached runner before it starts its listener. The job's creator already
        # holds the FIFO's read end, so the cancel is accepted and delivered once it starts.
        bootstrap = BOOTSTRAP.split("sys.exit")[0] + '''
spawn = q.subprocess.Popen
def slow_runner(args, *positional, **keywords):
    if isinstance(args, list) and len(args) > 2 and 'q.resume(' in str(args[2]):
        args = list(args)
        args[2] = 'import time; time.sleep(1.5); ' + args[2]
    return spawn(args, *positional, **keywords)
q.subprocess.Popen = slow_runner
sys.exit(q.main(sys.argv[2:]))
'''
        args = self.job_args("startup-cancel", "import time; time.sleep(30)", timeout=40)
        args[0] = "submit"
        submitter = self.launch(args, bootstrap)
        output, error = submitter.communicate(timeout=8)
        self.assertEqual(submitter.returncode, 0, error)
        self.assertIsNone(self.job("startup-cancel")["runnerPid"])
        cancel = self.invoke(self.cli("cancel", "startup-cancel"))
        self.assertEqual(cancel.returncode, 0, cancel.stderr)
        result = self.invoke(self.cli("wait", "startup-cancel", ["--max-wait", "8"]))
        self.assertEqual(result.returncode, 130, result.stderr)
        job = json.loads(result.stdout)
        self.assertEqual(job["status"], "cancelled")
        self.assertIsNone(job["childPgid"])
        self.assert_lock_free()

    def test_setup_failure_after_job_creation_records_terminal_error(self):
        failures = {
            "fifo-open": "q.open_cancel_reader = lambda directory: (_ for _ in ()).throw(OSError(24, 'Too many open files'))",
            "fifo-make": "q.os.mkfifo = lambda *args, **kwargs: (_ for _ in ()).throw(OSError(28, 'No space left on device'))",
        }
        for name, patch_line in failures.items():
            with self.subTest(name=name):
                bootstrap = BOOTSTRAP.split("sys.exit")[0] + patch_line + "\nsys.exit(q.main(sys.argv[2:]))\n"
                runner = self.launch(self.job_args(name), bootstrap)
                output, error = runner.communicate(timeout=8)
                self.assertEqual(runner.returncode, 125, error)
                job = self.job(name)
                self.assertEqual(job["status"], "error")
                self.assertIsNotNone(job["finishedAt"])
                self.assertIn("Errno", job["error"])
                # The job is terminal, not stale: wait reports the error instead of exit 4.
                result = self.invoke(self.cli("wait", name, ["--max-wait", "2"]))
                self.assertEqual(result.returncode, 125, result.stderr)
                self.assertIsNone(job["childPgid"])
                self.assert_lock_free()

    def test_submit_hangup_during_spawn_with_ignored_sigchld_cancels_and_reports(self):
        bootstrap = BOOTSTRAP.split("sys.exit")[0] + '''
q.signal.signal(q.signal.SIGCHLD, q.signal.SIG_IGN)
original = q.subprocess.Popen
def interrupted_spawn(argv, *args, **kwargs):
    if 'q.resume' in ' '.join(argv):
        # The runner PID stays pinned only if SIGCHLD is not ignored while submit can signal it.
        assert q.signal.getsignal(q.signal.SIGCHLD) == q.signal.SIG_DFL
    runner = original(argv, *args, **kwargs)
    if 'q.resume' in ' '.join(argv):
        q.signal.raise_signal(q.signal.SIGHUP)
    return runner
q.subprocess.Popen = interrupted_spawn
sys.exit(q.main(sys.argv[2:]))
'''
        args = self.job_args("submit-hup", "import time; time.sleep(30)", timeout=40)
        args[0] = "submit"
        submitter = self.launch(args, bootstrap)
        output, error = submitter.communicate(timeout=8)
        self.assertEqual(submitter.returncode, 130, error)
        self.assertTrue(json.loads(output)["cancelRequested"])
        result = self.invoke(self.cli("wait", "submit-hup", ["--max-wait", "6"]))
        self.assertEqual(result.returncode, 130, result.stderr)
        job = json.loads(result.stdout)
        self.assertEqual(job["status"], "cancelled")
        if job["childPgid"] is not None:
            self.assertFalse(qa.group_has_members(job["childPgid"]))
        self.assert_lock_free()

    def test_cancel_at_cleanup_entry_still_finishes_cleanup(self):
        runner_bootstrap = BOOTSTRAP.split("sys.exit")[0] + '''
original = q.ignore_runner_signals
calls = []
def cancelled_on_entry(signals):
    calls.append(1)
    if len(calls) == 1:
        raise q.Cancelled(q.signal.SIGTERM)
    return original(signals)
q.ignore_runner_signals = cancelled_on_entry
sys.exit(q.main(sys.argv[2:]))
'''
        runner = self.launch(self.job_args("cleanup-entry", "import time; time.sleep(.2)"), runner_bootstrap)
        result = self.finish(runner, "cleanup-entry", 0)
        self.assertEqual(result["status"], "succeeded")
        self.assertIsNotNone(result["finishedAt"])
        self.assertFalse(qa.group_has_members(result["childPgid"]))
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
            submitter = subprocess.Popen([sys.executable, "-c", TEST_SETUP + BOOTSTRAP, str(SCRIPT.parent), *args], env=self.env,
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
            # The interrupted write must not be retried into the same full pipe.
            self.assertEqual(submitter.wait(timeout=3), 130)
        finally:
            if writer is not None:
                os.close(writer)
            os.close(reader)

    def test_run_inheriting_ignored_sigchld_still_records_payload_failure(self):
        # Under SIG_IGN, Darwin reaps the payload at exit and Popen reports ECHILD as status 0.
        ignoring = "import signal; signal.signal(signal.SIGCHLD, signal.SIG_IGN); " + BOOTSTRAP
        runner = self.launch(self.job_args("ignored-sigchld", "import sys; sys.exit(3)"), bootstrap=ignoring)
        result = self.finish(runner, "ignored-sigchld", 3)
        self.assertEqual((result["status"], result["exitCode"]), ("failed", 3))
        self.assert_lock_free()

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
        natural_exit = self.root / "orphan-natural-exit"
        code = ("import time; from pathlib import Path; time.sleep(2.5); "
                f"Path({str(natural_exit)!r}).touch()")
        runner = self.launch(self.job_args("stale", code))
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
        self.await_job("later", lambda j: any("owner token of job stale" in r for r in j["reasons"]))
        self.finish(next_runner, "later", 0)
        self.assertTrue(natural_exit.exists(), "admission must not signal the orphan")
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
        # The payload waits for a release file, so a slow runner cannot finish it before the short wait.
        release = self.root / "release-short-wait"
        payload = ("import os, time\n"
                   f"while not os.path.exists({str(release)!r}):\n"
                   "    time.sleep(.02)\n")
        args = self.job_args("short-wait", payload, timeout=10)
        args[0] = "submit"
        self.assertEqual(self.invoke(args).returncode, 0)
        result = self.invoke(self.cli("wait", "short-wait", ["--max-wait", ".05"]))
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertTrue(json.loads(result.stdout)["live"])
        release.touch()
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


class OwnershipTests(unittest.TestCase):
    def test_procargs_candidates_preserve_padding_and_empty_arguments(self):
        raw = ((3).to_bytes(4, sys.byteorder, signed=True) + b"/path with spaces/python\0\0\0"
               + b"python\0\0-c\0A=one=two\0OWNER=value\0\0not=environment\0")
        self.assertEqual(qa.parse_process_env(raw, 123), ["python", "-c", "A=one=two", "OWNER=value", "not=environment"])
        for raw in (b"", (2).to_bytes(4, sys.byteorder, signed=True) + b"missing-exec-nul"):
            with self.subTest(raw=raw), self.assertRaisesRegex(OSError, "malformed KERN_PROCARGS2"):
                qa.parse_process_env(raw, 123)

    def test_sysctl_error_preserves_errno(self):
        with patch.object(qa, "_SYSCTL", return_value=-1), \
             patch.object(qa.ctypes, "get_errno", return_value=qa.errno.EPERM):
            with self.assertRaises(OSError) as error:
                qa._sysctl_read([1, 49, 123], qa.ctypes.create_string_buffer(16))
        self.assertEqual(error.exception.errno, qa.errno.EPERM)
        self.assertIn("sysctl [1, 49, 123]", str(error.exception))

    def test_identity_parses_command_with_spaces_and_rejects_bad_dates(self):
        line = "Thu Oct  1 12:34:56 2026 /an executable with spaces/python\n"
        with patch.object(qa.subprocess, "run", return_value=Mock(returncode=0, stdout=line)):
            self.assertEqual(qa.process_identity(123),
                             dict(pid=123, start="Thu Oct  1 12:34:56 2026",
                                  comm="/an executable with spaces/python"))
        with patch.object(qa.subprocess, "run", return_value=Mock(returncode=0, stdout="bad date python")):
            with self.assertRaisesRegex(RuntimeError, "malformed lstart/comm"):
                qa.process_identity(123)

    def test_changed_microsecond_start_uid_and_zombie_never_receive_signal(self):
        identity = dict(pid=123, start_us=123_000_001, uid=os.getuid(),
                        start="old", comm="python", proof="token")
        current = dict(pid=123, start_us=identity["start_us"], uid=os.getuid(), zombie=False)
        for changes in (dict(start_us=123_000_002), dict(uid=os.getuid() + 1), dict(zombie=True)):
            with self.subTest(changes=changes), \
                 patch.object(qa, "kernel_identity", return_value=dict(current, **changes)), \
                 patch.object(qa.os, "kill") as kill, patch.object(qa.os, "killpg") as killpg:
                self.assertFalse(qa.signal_owned_process(identity, signal.SIGKILL))
                kill.assert_not_called()
                killpg.assert_not_called()

    def test_token_match_is_exact_and_unreadable_nonancestry_is_not_owned(self):
        job = dict(jobId="job", ownerToken="a" * 32)
        rows = {pid: dict(pid=pid, ppid=1, pgid=pid, uid=os.getuid(), stat="S") for pid in (123, 124, 125)}
        def env(pid):
            if pid == 125:
                raise OSError(qa.errno.EPERM, "unreadable")
            return [qa.owner_entry(job) + ("-other" if pid == 123 else "")]
        with patch.object(qa, "process_snapshot", return_value=rows), \
             patch.object(qa, "process_env", side_effect=env), \
             patch.object(qa, "kernel_identity", side_effect=lambda pid: dict(pid=pid, start_us=pid * 1_000_000, uid=rows[pid]["uid"], zombie=False)), \
             patch.object(qa, "process_identity", side_effect=lambda pid, **unused: dict(pid=pid, start="date", comm="python")):
            self.assertEqual([p["pid"] for p in qa.owned_processes(job, 99)], [124])

    def test_foreign_uid_descendant_is_retained_without_environment_read_or_signal(self):
        job = dict(jobId="job", ownerToken="a" * 32)
        rows = {123: dict(pid=123, ppid=1, pgid=123, uid=os.getuid(), stat="S"),
                124: dict(pid=124, ppid=123, pgid=124, uid=os.getuid() + 1, stat="S")}
        with patch.object(qa, "process_snapshot", return_value=rows), \
             patch.object(qa, "process_env", return_value=[]) as env, \
             patch.object(qa, "kernel_identity", side_effect=lambda pid: dict(pid=pid, start_us=pid * 1_000_000, uid=rows[pid]["uid"],
                                                                     ppid=rows[pid]["ppid"], zombie=False)), \
             patch.object(qa, "process_identity", side_effect=lambda pid, **unused: dict(pid=pid, start="date", comm="python")):
            found = qa.owned_processes(job, 123)
        self.assertEqual([(p["pid"], p["proof"]) for p in found], [(123, "ancestry"), (124, "ancestry")])
        env.assert_called_once_with(123)
        with patch.object(qa, "kernel_identity", return_value=dict(found[1], zombie=False)), \
             patch.object(qa, "process_env") as env, patch.object(qa.os, "kill") as kill:
            self.assertFalse(qa.signal_owned_process(found[1], signal.SIGTERM))
            env.assert_not_called()
            kill.assert_not_called()

    def test_kernel_identity_reports_the_real_parent(self):
        self.assertEqual(qa.kernel_identity(os.getpid())["ppid"], os.getppid())

    def test_ancestry_is_proven_from_the_kernel_chain_of_the_pinned_execution(self):
        # The snapshot nominates 124 and 125 as descendants of payload 123. Each schedule is
        # what the kernel reports once the PID is pinned, after any reuse.
        job = dict(jobId="job", ownerToken="a" * 32)
        uid = os.getuid()
        rows = {123: dict(pid=123, ppid=1, pgid=123, uid=uid, stat="S"),
                124: dict(pid=124, ppid=123, pgid=123, uid=uid, stat="S"),
                125: dict(pid=125, ppid=124, pgid=123, uid=uid, stat="S")}
        def kernel(changes=None):
            table = {pid: dict(pid=pid, start_us=pid * 1_000_000, uid=uid, ppid=row["ppid"], zombie=False)
                     for pid, row in rows.items()}
            for pid, fields in (changes or {}).items():
                table[pid].update(fields)
            return lambda pid: dict(table[pid]) if pid in table else None
        schedules = {
            "consistent": (kernel(), [123, 124, 125]),
            # 124 exited and an unrelated process now holds its PID; 125 was reparented.
            "reused leaf": (kernel({124: dict(ppid=1, start_us=900_000_000), 125: dict(ppid=1)}), [123]),
            # 124's PID now names a process started after 125, so 125's recorded parent is gone.
            "reused link": (kernel({124: dict(start_us=900_000_000)}), [123, 124]),
            # The descendant's PID was reused by a process whose real parent is elsewhere.
            "reused pid": (kernel({125: dict(ppid=77, start_us=901_000_000)}), [123, 124]),
        }
        for name, (identity, expected) in schedules.items():
            with self.subTest(schedule=name), \
                 patch.object(qa, "process_snapshot", return_value=rows), \
                 patch.object(qa, "process_env", return_value=[]), \
                 patch.object(qa, "kernel_identity", side_effect=identity), \
                 patch.object(qa, "process_identity", side_effect=lambda pid, **unused: dict(pid=pid, start="date", comm="python")), \
                 patch.object(qa.os, "kill") as kill:
                found = qa.owned_processes(job, 123)
                self.assertEqual([p["pid"] for p in found], expected)
                self.assertTrue(all(p["proof"] == "ancestry" for p in found))
                kill.assert_not_called()

    def test_proven_identity_survives_lost_token_and_reparenting(self):
        identity = dict(pid=124, uid=os.getuid(), start_us=124_000_001,
                        start="child-start", comm="python", proof="ancestry")
        with patch.object(qa, "kernel_identity", return_value=dict(identity, zombie=False)), \
             patch.object(qa, "process_identity") as ps, \
             patch.object(qa, "process_env", return_value=[]) as env, patch.object(qa.os, "kill") as kill:
            self.assertTrue(qa.signal_owned_process(identity, signal.SIGTERM))
            env.assert_not_called()
            ps.assert_not_called()
            kill.assert_called_once_with(124, signal.SIGTERM)

    def test_kernel_start_microseconds_agree_with_live_ps_lstart(self):
        identity = qa.kernel_identity(os.getpid())
        human = qa.runner_start(os.getpid())
        seconds = int(time.mktime(time.strptime(human, "%a %b %d %H:%M:%S %Y")))
        self.assertEqual(identity["pid"], os.getpid())
        self.assertEqual(identity["uid"], os.getuid())
        self.assertEqual(identity["start_us"] // 1_000_000, seconds)
        self.assertFalse(identity["zombie"])

    def test_kinfo_pid_and_size_mismatch_fail_loudly(self):
        def read(mib, buffer, returned=648, pid=123):
            self.assertEqual(mib, [1, 14, 1, 123])
            value = qa.ProcessTimeval.from_buffer(buffer)
            value.seconds, value.microseconds = 1_700_000_000, 123456
            qa.ctypes.c_int.from_buffer(buffer, 40).value = pid
            qa.ctypes.c_uint.from_buffer(buffer, 420).value = os.getuid()
            qa.ctypes.c_byte.from_buffer(buffer, 36).value = 2
            return returned
        with patch.object(qa, "_sysctl_read", side_effect=read):
            self.assertEqual(qa.kernel_identity(123)["start_us"], 1_700_000_000_123456)
        for size, pid, message in ((647, 123, "size mismatch"), (648, 124, "PID mismatch")):
            with self.subTest(size=size, pid=pid), \
                 patch.object(qa, "_sysctl_read", side_effect=lambda mib, buf: read(mib, buf, size, pid)):
                with self.assertRaisesRegex(RuntimeError, message):
                    qa.kernel_identity(123)

    def test_dead_identity_is_dropped_after_one_inspection(self):
        previous = dict(pid=123, start_us=123_000_001, uid=os.getuid(), pgid=123,
                        start="date", comm="python", proof="token")
        for current in (None, dict(previous, start_us=123_000_002, zombie=False), dict(previous, zombie=True)):
            with self.subTest(current=current):
                owned = qa.OwnedProcesses({}, 99)
                key = qa.identity_key(previous)
                owned.identities[key] = previous
                owned.escaped[key] = "retained"
                with patch.object(qa, "owned_processes", return_value=[]), \
                     patch.object(qa, "kernel_identity", return_value=current) as inspect:
                    self.assertEqual(owned.snapshot(time.monotonic() + 1), ([], True))
                    self.assertEqual(owned.snapshot(time.monotonic() + 1), ([], True))
                    inspect.assert_called_once_with(123)
                self.assertNotIn(key, owned.identities)
                self.assertEqual(owned.escaped[key], "exited")

    def test_slow_identity_snapshot_stops_at_deadline_and_is_incomplete(self):
        job = dict(jobId="slow", ownerToken="a" * 32)
        rows = {pid: dict(pid=pid, ppid=1, pgid=pid, uid=os.getuid(), stat="S") for pid in range(123, 133)}
        clock = [0.0]
        def human(pid, **unused):
            clock[0] += .2
            return dict(pid=pid, start="date", comm="python")
        with patch.object(qa.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(qa, "process_snapshot", return_value=rows), \
             patch.object(qa, "kernel_identity", side_effect=lambda pid: dict(pid=pid, start_us=pid, uid=os.getuid(), zombie=False)), \
             patch.object(qa, "process_env", return_value=[qa.owner_entry(job)]), \
             patch.object(qa, "process_identity", side_effect=human) as inspect:
            owned = qa.OwnedProcesses(job, 99)
            remaining, complete = owned.snapshot(.35)
        self.assertFalse(complete)
        self.assertEqual(inspect.call_count, 2)
        self.assertAlmostEqual(clock[0], .4)
        self.assertTrue(remaining)
        self.assertIn("deadline", owned.last_incomplete)

    def test_candidate_disappearance_is_settled_or_incomplete(self):
        job = dict(jobId="job", ownerToken="a" * 32)
        row = dict(pid=123, ppid=1, pgid=123, uid=os.getuid(), stat="S")
        native = dict(pid=123, start_us=123_000_001, uid=os.getuid(), zombie=False)
        for after in (None, native):
            with self.subTest(after=after), patch.object(qa, "process_snapshot", return_value={123: row}), \
                 patch.object(qa, "kernel_identity", side_effect=[native, after]), \
                 patch.object(qa, "process_env", return_value=[qa.owner_entry(job)]), \
                 patch.object(qa, "process_identity", return_value=None):
                if after is None:
                    observed = []
                    self.assertEqual(qa.owned_processes(job, 99, observed=observed), [])
                    self.assertEqual(observed, [123])
                else:
                    with self.assertRaisesRegex(qa.SnapshotIncomplete, "unsettled owned identity"):
                        qa.owned_processes(job, 99)
        with patch.object(qa, "process_snapshot", return_value={123: row}), \
             patch.object(qa, "kernel_identity", return_value=native), \
             patch.object(qa, "process_env", side_effect=OSError(qa.errno.ESRCH, "gone")):
            self.assertEqual(qa.owned_processes(job, 99), [])

    def test_confirmation_needs_two_complete_empty_passes_after_every_reset(self):
        previous = dict(pid=123, start_us=123, uid=os.getuid(), pgid=123,
                        start="date", comm="python", proof="token")
        sequence = [([previous], True), ([], True), ([], False), ([], True),
                    ([previous], True), ([], True), ([], True)]
        owned, child, clock = qa.OwnedProcesses({}, 99), Mock(pid=99), [0.0]
        def sleep(seconds):
            clock[0] += seconds + .001
        with patch.object(owned, "snapshot", side_effect=sequence) as snapshots, \
             patch.object(owned, "signal") as signal_owned, \
             patch.object(qa, "group_has_members", return_value=False), \
             patch.object(qa.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(qa.time, "sleep", side_effect=sleep):
            qa.confirm_owned_exit(child, owned, 1)
        self.assertEqual(snapshots.call_count, 7)
        self.assertGreaterEqual(clock[0], .6)
        self.assertEqual(signal_owned.call_args_list[0].args, ([previous], signal.SIGKILL))
        clock[0] = 0
        with patch.object(owned, "snapshot", return_value=([], False)), \
             patch.object(qa, "group_has_members", return_value=False), \
             patch.object(qa.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(qa.time, "sleep", side_effect=sleep):
            with self.assertRaisesRegex(RuntimeError, "completeness uncertain"):
                qa.confirm_owned_exit(child, owned, .3)

    def test_transient_owned_process_resets_empty_confirmation(self):
        owned, child, clock = qa.OwnedProcesses({}, 99), Mock(pid=99), [0.0]
        activity = iter([False, True, False, False])
        def snapshot(deadline):
            owned.saw_owned = next(activity)
            return [], True
        def sleep(seconds):
            clock[0] += seconds + .001
        with patch.object(owned, "snapshot", side_effect=snapshot) as snapshots, \
             patch.object(qa, "group_has_members", return_value=False), \
             patch.object(qa.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(qa.time, "sleep", side_effect=sleep):
            qa.confirm_owned_exit(child, owned, 1)
        self.assertEqual(snapshots.call_count, 4)

    def test_owner_header_requires_exact_lowercase_32_hex_token(self):
        valid = TEST_OWNER_PREFIX + "a" * 32 + "=job"
        invalid = [TEST_OWNER_PREFIX + "a" * 31 + "=short", TEST_OWNER_PREFIX + "a" * 33 + "=long",
                   TEST_OWNER_PREFIX + "A" * 32 + "=uppercase", TEST_OWNER_PREFIX + "name=not-token"]
        self.assertEqual(qa.owner_jobs([valid, *invalid]), ["job"])


class PureTests(unittest.TestCase):
    def test_blender_app_bundle_executable_blocks_package_job(self):
        process = dict(comm="/Applications/Blender.app/Contents/MacOS/Blender",
                       args="/Applications/Blender.app/Contents/MacOS/Blender -b scene.blend -f 1")
        self.assertEqual(qa.classify_process(process, "package"), "blocker")
        self.assertTrue(qa.is_heavy("/usr/local/bin/blender"))
        self.assertFalse(qa.is_heavy("/Applications/T3 Code.app/Contents/MacOS/T3 Code"))

    def test_counter_survives_failed_write_and_next_ticket_continues(self):
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            path, ticket = qa.acquire_ticket(state, "first", time.monotonic() + 3)
            qa.release_ticket(path, ticket)
            counter = state / "queue" / "counter"
            self.assertEqual(counter.read_text(), "1")
            real_write = Path.write_text
            def failing(self, *args, **kwargs):
                if self.name == "counter.tmp":
                    raise OSError(28, "No space left on device")
                return real_write(self, *args, **kwargs)
            with patch.object(Path, "write_text", failing):
                with self.assertRaises(OSError):
                    qa.acquire_ticket(state, "second", time.monotonic() + 3)
            self.assertEqual(counter.read_text(), "1")
            path, ticket = qa.acquire_ticket(state, "third", time.monotonic() + 3)
            self.assertEqual(path.name, "000000000002.third")
            qa.release_ticket(path, ticket)

    def setUp(self):
        # These tests mock payload Popen; never inspect or signal their fictitious PIDs.
        for name in ("owner_blockers", "owned_processes"):
            mock = patch.object(qa, name, return_value=([], []) if name == "owner_blockers" else [])
            mock.start()
            self.addCleanup(mock.stop)

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

    def test_service_without_explicit_ids_blocks_every_simulator(self):
        service = f"xcodebuild test-without-building -only-testing:{qa.SERVICE_TEST}"
        for destination in ("", " -destination platform=iOS Simulator,name=iPhone 16,OS=18.0",
                            " -destination platform=iOS Simulator,id=other -destination platform=iOS Simulator,name=iPhone 16"):
            process = dict(comm="xcodebuild", args=service + destination)
            with self.subTest(destination=destination):
                self.assertEqual(qa.classify_process(process, "simulator", "ours"), "blocker")
                self.assertEqual(qa.classify_process(process, "package"), "ignored")
        process = dict(comm="xcodebuild", args=service + " -destination platform=iOS Simulator,id=other"
                       " -destination platform=iOS Simulator,id=third")
        self.assertEqual(qa.classify_process(process, "simulator", "ours"), "ignored")

    def test_xcodebuild_without_all_markers_blocks(self):
        for args in ("xcodebuild", f"xcodebuild -only-testing {qa.SERVICE_TEST}",
                     "xcodebuild test-without-building -only-testing WrongTest",
                     f"xcodebuild test-without-building echo {qa.SERVICE_TEST}",
                     f"xcodebuild test-without-building -only-testing {qa.SERVICE_TEST} -only-testing OtherUITests",
                     f"xcodebuild test-without-building -only-testing:OtherUITests -only-testing:{qa.SERVICE_TEST}",
                     f"xcodebuild build test-without-building -only-testing:{qa.SERVICE_TEST}",
                     f"xcodebuild test-without-building build-for-testing -only-testing:{qa.SERVICE_TEST}"):
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

    def test_cancel_writes_fifo_and_never_signals_a_pid(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "live.lock").touch()
            os.mkfifo(directory / qa.CANCEL_FIFO, 0o600)
            qa.write_job(directory, dict(jobId="fifo", runnerPid=os.getpid(), runnerStart="x",
                                         cancelChannel=qa.CANCEL_FIFO))
            with (directory / "live.lock").open("a+") as live:
                fcntl.flock(live, fcntl.LOCK_EX)
                with patch.object(qa.os, "kill") as kill, patch.object(qa.os, "killpg") as killpg, \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    # Live lock held but no runner reading: nothing is sent anywhere.
                    self.assertEqual(qa.cancel_job(directory), 4)
                    reader = os.open(directory / qa.CANCEL_FIFO, os.O_RDONLY | os.O_NONBLOCK)
                    try:
                        self.assertEqual(qa.cancel_job(directory), 0)
                        self.assertEqual(os.read(reader, 8), b"c")
                    finally:
                        os.close(reader)
                    kill.assert_not_called()
                    killpg.assert_not_called()

    def test_cancel_reports_reader_gone_between_open_and_write(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "live.lock").touch()
            os.mkfifo(directory / qa.CANCEL_FIFO, 0o600)
            qa.write_job(directory, dict(jobId="gone", cancelChannel=qa.CANCEL_FIFO))
            reader = os.open(directory / qa.CANCEL_FIFO, os.O_RDONLY | os.O_NONBLOCK)
            try:
                with (directory / "live.lock").open("a+") as live:
                    fcntl.flock(live, fcntl.LOCK_EX)
                    with patch.object(qa.os, "write", side_effect=BrokenPipeError(32, "Broken pipe")), \
                         contextlib.redirect_stderr(io.StringIO()):
                        self.assertEqual(qa.cancel_job(directory), 4)
            finally:
                os.close(reader)

    def test_listener_stop_failure_never_hangs_and_disables_delivery(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            os.mkfifo(directory / qa.CANCEL_FIFO, 0o600)
            listener = qa.CancelListener(directory)
            listener.start()
            with patch.object(qa.os, "write", side_effect=OSError(5, "Input/output error")):
                with self.assertRaises(OSError):
                    listener.stop()
            self.assertFalse(listener.active)
            # A cancel that arrives after cleanup began is read but never delivered.
            with patch.object(qa.signal, "pthread_kill") as deliver:
                writer = os.open(directory / qa.CANCEL_FIFO, os.O_WRONLY | os.O_NONBLOCK)
                os.write(writer, b"c")
                os.write(writer, qa.STOP_LISTENER)
                os.close(writer)
                listener.thread.join(timeout=3)
                deliver.assert_not_called()
            self.assertFalse(listener.thread.is_alive())
            os.close(listener.fd)

    def test_listener_is_owned_before_its_start_can_be_interrupted(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            os.mkfifo(directory / qa.CANCEL_FIFO, 0o600)
            listener = qa.CancelListener(directory)
            with patch.object(qa.threading.Thread, "start", side_effect=qa.Cancelled(signal.SIGTERM)):
                with self.assertRaises(qa.Cancelled):
                    listener.start()
            # The caller already holds the object, so cleanup can still close its fd.
            self.assertIsNotNone(listener.thread)
            listener.thread = None
            listener.stop()
            with self.assertRaises(OSError):
                os.fstat(listener.fd)

    def test_cancel_refuses_legacy_job_without_channel(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "live.lock").touch()
            qa.write_job(directory, dict(jobId="legacy", runnerPid=os.getpid(),
                                         runnerStart=qa.runner_start(os.getpid())))
            with (directory / "live.lock").open("a+") as live:
                fcntl.flock(live, fcntl.LOCK_EX)
                stderr = io.StringIO()
                with patch.object(qa.os, "kill") as kill, contextlib.redirect_stderr(stderr):
                    self.assertEqual(qa.cancel_job(directory), 4)
                kill.assert_not_called()
                self.assertIn("without a cancel channel", stderr.getvalue())

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

    def test_failed_job_record_setup_leaves_the_id_reusable(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = Mock(state_dir=root / "state", job_id="no-space", kind="package", argv=["unused"],
                        cwd=root, device=None, admission_deadline=3, timeout=1)
            def full_disk(directory, job):
                (directory / "job.json.tmp").write_text("partial")
                raise OSError(28, "No space left on device")
            original_open = Path.open
            def full_disk_lock(path, *rest, **keywords):
                if path.name == "live.lock":
                    raise OSError(28, "No space left on device")
                return original_open(path, *rest, **keywords)
            for name, failure in (("record", patch.object(qa, "write_job", side_effect=full_disk)),
                                  ("live lock", patch.object(Path, "open", autospec=True, side_effect=full_disk_lock))):
                with self.subTest(failure=name), failure:
                    with self.assertRaisesRegex(qa.JobSetupError, "cannot create the job record: .*No space left"):
                        qa.create_job(args)
                self.assertFalse((root / "state/jobs/no-space").exists())
            directory, live, job = qa.create_job(args)
            live.close()
            self.assertEqual(qa.read_job(directory)["status"], "queued")

    def test_submit_interrupted_while_waiting_for_its_ticket_records_cancelled(self):
        for sig in qa.RUNNER_SIGNALS:
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                args = Mock(state_dir=root / "state", job_id="interrupted", kind="package", argv=["unused"],
                            cwd=root, device=None, admission_deadline=3, timeout=1)
                directory, live, job = qa.create_job(args)
                before = {s: signal.getsignal(s) for s in qa.RUNNER_SIGNALS}
                def waiting(*unused):
                    # Without submit's handler this signal would kill the test runner itself.
                    self.assertNotIn(signal.getsignal(sig), (signal.SIG_DFL, signal.default_int_handler))
                    os.kill(os.getpid(), sig)
                    self.fail("the signal did not interrupt the ticket wait")
                with patch.object(qa, "acquire_ticket", side_effect=waiting), \
                     patch.object(qa.subprocess, "Popen") as spawn:
                    code = qa.submit(directory, live, job, root / "lock", qa.open_cancel_reader(directory))
                self.assertEqual(code, 130)
                spawn.assert_not_called()
                result = qa.read_job(directory)
                self.assertEqual((result["status"], result["signal"]), ("cancelled", sig))
                self.assertEqual({s: signal.getsignal(s) for s in qa.RUNNER_SIGNALS}, before)
                self.assertFalse(qa.live_report(directory)["live"])

    def test_interruption_between_job_creation_and_handlers_is_recorded(self):
        real_reader = qa.open_cancel_reader
        for command in ("run", "submit"):
            for sig in qa.RUNNER_SIGNALS:
                with self.subTest(command=command, signal=sig), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp)
                    def reader(directory):
                        # Unblocked, this signal would take the default action in the test runner.
                        self.assertIn(sig, signal.pthread_sigmask(signal.SIG_BLOCK, []))
                        os.kill(os.getpid(), sig)
                        return real_reader(directory)
                    handlers = {s: signal.getsignal(s) for s in (*qa.RUNNER_SIGNALS, signal.SIGCHLD)}
                    mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
                    argv = [command, "--state-dir", str(root / "state"), "--lock", str(root / "lock"),
                            "--job-id", "handoff", "--kind", "package", "--cwd", str(root),
                            "--admission-deadline", "3", "--timeout", "1", "--", sys.executable, "-c", "pass"]
                    with patch.object(qa, "open_cancel_reader", side_effect=reader), \
                         patch.object(qa.subprocess, "Popen") as spawn:
                        self.assertEqual(qa.main(argv), 130)
                    spawn.assert_not_called()
                    result = qa.read_job(root / "state/jobs/handoff")
                    self.assertEqual((result["status"], result["signal"]), ("cancelled", sig))
                    self.assertFalse(qa.live_report(root / "state/jobs/handoff")["live"])
                    self.assertEqual({s: signal.getsignal(s) for s in handlers}, handlers)
                    self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, []), mask)

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
                def members(pgid, **unused):
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
                self.assertAlmostEqual(clock[0], 2 if members_remain else 1.1)
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
