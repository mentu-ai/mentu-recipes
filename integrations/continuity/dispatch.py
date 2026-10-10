#!/usr/bin/env python3
"""One admitted recipe occurrence, with durable reporting. POSIX, Python 3.10+.

This is a boundary adapter, not a scheduler, ticket service, or MP consumer. An
operator provisions a private JSON policy and an authorized caller supplies only
occurrence/work/trigger references. `prepare` freezes input bytes and the runner's
review plan; `run --plan-digest DIGEST` admits that exact plan. Repeating an
occurrence never launches a second execution, including after an uncertain crash.

Request: {"version":1,"occurrence":"...","work_ref":"...","trigger_ref":"..."}
Policy fields: version, namespace, runner (absolute executable), runner_sha256, workspace,
recipe ({path, sha256}), backend, model, journal_dir, manifest_var, inputs,
inherit_env, reporter ({argv, timeout_seconds}); optional plan_timeout_seconds
(30) and run_timeout_seconds (300). Input: id, path OR HTTPS url, sha256,
max_bytes, timeout_seconds, optional auth_env (HTTPS Bearer only), and optional
use (context or authorized_prompt). Remote bytes are data; only the fixed recipe
can authorize interpreting a specifically pinned prompt resource as instructions.

The recipe consumes $CONTINUITY_MANIFEST and $CONTINUITY_MANIFEST_SHA256 (or
the policy's variable name and its _SHA256 companion). Both are admission vars.
Requests cannot select prompts, URLs, commands, providers, credentials or policy.
The calling service must fix its policy path; this CLI does not authenticate a
remote caller. Same-UID processes are not an isolation boundary.

Reporter argv is fixed operator code, never a shell string. It receives result
JSON on stdin and returns {"evidence":"source-qualified-reference"}. It MUST be
idempotent by request_key: its external write can succeed before this process
records the response. A failed/lost report is retried with the retained result,
never by rerunning a model. No receipt proves work acceptance or epistemic truth.

Exit codes: 0 prepared/reported-ok/status, 2 refused, 3 busy, 4 unresolved,
5 report_pending, 10 reported-failed. JSON only on stdout; child logs are private
files. A consumer may acknowledge its own event only after a durable `reported`
receipt and its own disposition policy. This adapter never acknowledges MP.

Run timeout terminates this invocation's process group and marks it unresolved;
that cannot prove that every external effect stopped. No automatic recovery
executes/resumes uncertain work. A later call may reconcile existing terminal
runner artifacts and report them. Original source URLs are never refetched by
run: the reviewed retained snapshots are the inputs of this occurrence.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import multiprocessing
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


MAX_JSON = 4 * 1024 * 1024
MAX_INPUT = 4 * 1024 * 1024
MAX_TOTAL_INPUT = 16 * 1024 * 1024
HEX = re.compile(r"[a-f0-9]{64}\Z")
NAME = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{0,127}\Z")
VARIABLE = re.compile(r"[A-Z][A-Z0-9_]{0,95}\Z")
RUN_ID = re.compile(r"run_[A-Za-z0-9_-]{1,128}\Z")


class Refused(Exception):
    """A safe, fixed error code, never raw provider/network exception text."""


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def encoded(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")) + "\n").encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise Refused("regular_file_required")
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        return digest.hexdigest()
    except OSError as exc:
        raise Refused("file_unavailable") from exc


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise Refused("duplicate_json_key")
        result[key] = value
    return result


def parse(data):
    try:
        return json.loads(data, object_pairs_hook=pairs)
    except (ValueError, UnicodeError) as exc:
        raise Refused("invalid_json") from exc


def exact(value, required, optional=()):
    if not isinstance(value, dict) or not set(required) <= value.keys() or value.keys() - set(required) - set(optional):
        raise Refused("unsupported_or_missing_fields")


def text_value(value, maximum=2048):
    return isinstance(value, str) and 0 < len(value) <= maximum and not any(ord(c) < 32 for c in value)


def number(value, maximum, minimum=1):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and minimum <= value <= maximum


def private_directory(path):
    if not path.is_absolute():
        raise Refused("absolute_path_required")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise Refused("private_owned_directory_required")


def read_bytes(path, limit=MAX_JSON, private=False):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        with os.fdopen(fd, "rb") as stream:
            st = os.fstat(stream.fileno())
            if not stat.S_ISREG(st.st_mode):
                raise Refused("regular_file_required")
            if private and (st.st_uid != os.getuid() or st.st_mode & 0o077):
                raise Refused("private_owned_file_required")
            data = stream.read(limit + 1)
        if len(data) > limit:
            raise Refused("file_size_limit")
        return data
    except OSError as exc:
        raise Refused("file_unavailable") from exc


def atomic_bytes(path, data):
    fd, temporary = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json(path, value):
    atomic_bytes(path, encoded(value))


def absolute(value):
    if not text_value(value) or not Path(value).is_absolute():
        raise Refused("absolute_path_required")
    return Path(value)


def load_policy(path):
    path = absolute(str(path))
    # A private file in a private immediate parent is the operator boundary.
    parent = path.parent.lstat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o077:
        raise Refused("private_policy_parent_required")
    policy = parse(read_bytes(path, private=True))
    exact(policy, {"version", "namespace", "runner", "runner_sha256", "workspace", "recipe", "backend", "model",
                   "journal_dir", "manifest_var", "inputs", "inherit_env", "reporter"},
          {"plan_timeout_seconds", "run_timeout_seconds"})
    if type(policy["version"]) is not int or policy["version"] != 1 or not NAME.fullmatch(str(policy["namespace"])):
        raise Refused("invalid_policy_version_or_namespace")
    for field in ("runner", "workspace", "journal_dir"):
        absolute(policy[field])
    if not Path(policy["workspace"]).is_dir() or not os.access(policy["runner"], os.X_OK):
        raise Refused("runner_or_workspace_unavailable")
    if not HEX.fullmatch(str(policy["runner_sha256"])):
        raise Refused("invalid_runner_digest")
    exact(policy["recipe"], {"path", "sha256"})
    absolute(policy["recipe"]["path"])
    if not HEX.fullmatch(str(policy["recipe"]["sha256"])):
        raise Refused("invalid_recipe_digest")
    if not NAME.fullmatch(str(policy["backend"])) or not text_value(policy["model"], 128):
        raise Refused("explicit_backend_and_model_required")
    if not VARIABLE.fullmatch(str(policy["manifest_var"])):
        raise Refused("invalid_manifest_variable")
    env = policy["inherit_env"]
    if not isinstance(env, list) or len(env) > 64 or len(set(env)) != len(env) or any(not VARIABLE.fullmatch(str(k)) for k in env):
        raise Refused("invalid_environment_allowlist")
    for field, default, maximum in (("plan_timeout_seconds", 30, 300), ("run_timeout_seconds", 300, 86400)):
        if not number(policy.get(field, default), maximum):
            raise Refused("invalid_process_time_limit")
    reporter = policy["reporter"]
    exact(reporter, {"argv", "timeout_seconds"})
    argv = reporter["argv"]
    if not isinstance(argv, list) or not 1 <= len(argv) <= 32 or not all(text_value(a) for a in argv):
        raise Refused("reporter_argv_required")
    absolute(argv[0])
    if not os.access(argv[0], os.X_OK) or not number(reporter["timeout_seconds"], 300):
        raise Refused("invalid_reporter")
    inputs = policy["inputs"]
    if not isinstance(inputs, list) or len(inputs) > 32:
        raise Refused("invalid_input_list")
    ids, total = set(), 0
    for resource in inputs:
        exact(resource, {"id", "sha256", "max_bytes", "timeout_seconds"}, {"path", "url", "auth_env", "use"})
        ident = resource["id"]
        if not isinstance(ident, str) or not NAME.fullmatch(ident) or ident in ids:
            raise Refused("invalid_or_duplicate_input_id")
        ids.add(ident)
        if not HEX.fullmatch(str(resource["sha256"])) or type(resource["max_bytes"]) is not int or not number(resource["max_bytes"], MAX_INPUT):
            raise Refused("invalid_input_digest_or_size")
        if not number(resource["timeout_seconds"], 120) or resource.get("use", "context") not in ("context", "authorized_prompt"):
            raise Refused("invalid_input_time_or_use")
        total += resource["max_bytes"]
        if ("path" in resource) == ("url" in resource):
            raise Refused("exactly_one_input_location_required")
        if "path" in resource:
            absolute(resource["path"])
            if "auth_env" in resource:
                raise Refused("local_input_cannot_have_auth")
        else:
            url = urllib.parse.urlsplit(resource["url"])
            if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment:
                raise Refused("exact_https_input_required")
            if "auth_env" in resource and (not VARIABLE.fullmatch(str(resource["auth_env"])) or resource["auth_env"] in env):
                raise Refused("fetch_credential_must_not_enter_runner_environment")
    if total > MAX_TOTAL_INPUT:
        raise Refused("total_input_size_limit")
    return policy


def load_request(path):
    request = parse(read_bytes(path, 65536))
    exact(request, {"version", "occurrence", "work_ref", "trigger_ref"})
    if type(request["version"]) is not int or request["version"] != 1 or not all(text_value(request[k], 1024) for k in ("occurrence", "work_ref", "trigger_ref")):
        raise Refused("invalid_request")
    return request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Refused("input_redirect_refused")


def read_https(resource):
    headers = {"Accept-Encoding": "identity"}
    if resource.get("auth_env"):
        token = os.environ.get(resource["auth_env"])
        if not token or "\r" in token or "\n" in token:
            raise Refused("input_credential_unavailable")
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(resource["url"], headers=headers)
    # Ambient proxy settings cannot redirect an explicitly bound credential.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=resource["timeout_seconds"]) as response:
        if response.status != 200 or response.geturl() != resource["url"]:
            raise Refused("input_response_refused")
        data = response.read(resource["max_bytes"] + 1)
    if len(data) > resource["max_bytes"]:
        raise Refused("input_size_limit")
    return data


def fetch_worker(resource, connection):
    try:
        data = read_bytes(Path(resource["path"]), resource["max_bytes"]) if "path" in resource else read_https(resource)
        connection.send((True, data))
    except Refused as exc:
        connection.send((False, str(exc)))
    except Exception:
        connection.send((False, "input_fetch_failed"))
    finally:
        connection.close()


def fetch(resource):
    # A separate short-lived resolver enforces a wall deadline even for DNS or
    # stalled local storage. It performs no model work and receives no new URLs.
    context = multiprocessing.get_context("fork")
    reader, writer = context.Pipe(duplex=False)
    process = context.Process(target=fetch_worker, args=(resource, writer), daemon=True)
    process.start()
    writer.close()
    try:
        if not reader.poll(resource["timeout_seconds"]):
            raise Refused("input_fetch_timeout")
        try:
            ok, data = reader.recv()
        except EOFError as exc:
            raise Refused("input_fetch_failed") from exc
        if not ok:
            raise Refused(data)
        if sha(data) != resource["sha256"]:
            raise Refused("input_digest_mismatch")
        return data
    finally:
        reader.close()
        process.join(0.1)
        if process.is_alive():
            process.terminate()
            process.join(1)
        if process.is_alive():
            process.kill()
            process.join()


@contextlib.contextmanager
def occurrence_lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise Refused("private_lock_required")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
        else:
            yield True
    finally:
        os.close(fd)


class Dispatch:
    def __init__(self, policy, request):
        self.policy, self.request = policy, request
        self.policy_digest, self.request_digest = sha(encoded(policy)), sha(encoded(request))
        self.key = sha((policy["namespace"] + "\0" + request["occurrence"]).encode())
        self.request_key = "continuity:" + self.key
        self.directory = Path(policy["journal_dir"]) / self.key
        self.state_path = self.directory / "state.json"
        self.state = None

    def result(self, disposition, **fields):
        return {"version": 1, "disposition": disposition, "request_key": self.request_key,
                "occurrence": self.request["occurrence"], "work_ref": self.request["work_ref"],
                "trigger_ref": self.request["trigger_ref"], "journal": str(self.directory), **fields}

    def save(self):
        atomic_json(self.state_path, self.state)

    def load(self):
        if self.state_path.exists():
            self.state = parse(read_bytes(self.state_path, private=True))
            if self.state.get("policy_digest") != self.policy_digest or self.state.get("request_digest") != self.request_digest:
                raise Refused("occurrence_conflict")
            if self.state.get("request_key") != self.request_key:
                raise Refused("journal_binding_mismatch")
            phase = self.state.get("phase")
            if self.state.get("version") != 1 or phase not in ("new", "prepared", "launch_intent", "unresolved", "report_pending", "reported"):
                raise Refused("invalid_journal_state")
            if phase != "new" and any(not HEX.fullmatch(str(self.state.get(k, ""))) for k in
                                      ("plan_digest", "manifest_digest", "plan_file_digest")):
                raise Refused("incomplete_journal_state")
            if phase in ("report_pending", "reported") and (not HEX.fullmatch(str(self.state.get("result_digest", ""))) or
                    self.state.get("outcome") not in ("ok", "failed") or not RUN_ID.fullmatch(str(self.state.get("run_id", "")))):
                raise Refused("incomplete_result_state")
            if phase == "reported" and (not text_value(self.state.get("evidence")) or not text_value(self.state.get("reported_at"))):
                raise Refused("incomplete_report_receipt")
        else:
            self.state = {"version": 1, "policy_digest": self.policy_digest, "request_digest": self.request_digest,
                          "request_key": self.request_key, "phase": "new"}

    def environment(self):
        return {k: os.environ[k] for k in self.policy["inherit_env"] if k in os.environ}

    def check_recipe(self):
        if sha(read_bytes(Path(self.policy["recipe"]["path"]))) != self.policy["recipe"]["sha256"]:
            raise Refused("recipe_digest_mismatch")

    def check_runner(self):
        if file_sha(self.policy["runner"]) != self.policy["runner_sha256"]:
            raise Refused("runner_digest_mismatch")

    def command(self, verb):
        manifest = str(self.directory / "manifest.json")
        variable = self.policy["manifest_var"]
        return [self.policy["runner"], verb, self.policy["recipe"]["path"], "--workspace", self.policy["workspace"],
                "--backend", self.policy["backend"], "--model", self.policy["model"],
                "--var", variable + "=" + manifest, "--var", variable + "_SHA256=" + self.state["manifest_digest"]]

    def process(self, argv, prefix, timeout, stdin=None):
        # Only the fixed runner/reporter can execute. No shell or caller argv.
        output, errors = self.directory / (prefix + ".stdout"), self.directory / (prefix + ".stderr")
        out_fd = os.open(output, os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        err_fd = os.open(errors, os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(out_fd, "wb") as out, os.fdopen(err_fd, "wb") as err:
            try:
                child = subprocess.Popen(argv, cwd=self.policy["workspace"], env=self.environment(),
                                         stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                         stdout=out, stderr=err, start_new_session=True)
            except OSError:
                return None, "process_start_failed"
            try:
                child.communicate(input=stdin, timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    child.wait()
                return child.returncode, "process_interrupted_or_timed_out"
            return child.returncode, None

    def validate_plan(self, plan):
        if not isinstance(plan, dict) or plan.get("version") != 1 or not HEX.fullmatch(str(plan.get("digest", ""))):
            raise Refused("invalid_runner_plan")
        if Path(plan.get("workspace", "")).resolve() != Path(self.policy["workspace"]).resolve():
            raise Refused("plan_workspace_mismatch")
        def visit(node):
            steps, children = node.get("steps"), node.get("children")
            if not isinstance(steps, list) or not isinstance(children, list) or not (steps or children):
                raise Refused("empty_or_invalid_plan")
            for step in steps:
                if step.get("backend") != self.policy["backend"] or step.get("model") != self.policy["model"]:
                    raise Refused("plan_backend_or_model_mismatch")
            for child in children:
                visit(child)
        visit(plan)
        if Path(plan.get("source", "")).resolve() != Path(self.policy["recipe"]["path"]).resolve():
            raise Refused("plan_recipe_mismatch")

    def get_plan(self, prefix):
        self.check_runner()
        code, error = self.process(self.command("plan"), prefix, self.policy.get("plan_timeout_seconds", 30))
        if error or code != 0:
            raise Refused("runner_plan_failed")
        plan = parse(read_bytes(self.directory / (prefix + ".stdout"), private=True))
        self.validate_plan(plan)
        return plan

    def frozen(self):
        raw = read_bytes(self.directory / "manifest.json", private=True)
        if sha(raw) != self.state["manifest_digest"]:
            raise Refused("retained_manifest_changed")
        manifest = parse(raw)
        if manifest.get("request") != self.request or manifest.get("policy_digest") != self.policy_digest:
            raise Refused("retained_manifest_binding_mismatch")
        expected = {r["id"]: r for r in self.policy["inputs"]}
        resources = manifest.get("inputs", [])
        if len(resources) != len(expected) or {r.get("id") for r in resources} != expected.keys():
            raise Refused("retained_inputs_mismatch")
        for resource in resources:
            definition = expected[resource["id"]]
            path = self.directory / "inputs" / (resource["id"] + ".bin")
            if resource["snapshot"] != str(path) or sha(read_bytes(path, definition["max_bytes"], private=True)) != definition["sha256"]:
                raise Refused("retained_input_changed")
        plan_raw = read_bytes(self.directory / "plan.json", private=True)
        if sha(plan_raw) != self.state["plan_file_digest"]:
            raise Refused("retained_plan_changed")
        plan = parse(plan_raw)
        self.validate_plan(plan)
        if plan["digest"] != self.state["plan_digest"]:
            raise Refused("retained_plan_binding_mismatch")
        return plan

    def prepare(self):
        if self.state["phase"] != "new":
            self.frozen()
            return self.view()
        self.check_recipe()
        self.save()  # Claims the occurrence identity even if resolution fails.
        inputs_dir = self.directory / "inputs"
        private_directory(inputs_dir)
        resources = []
        for resource in self.policy["inputs"]:
            data = fetch(resource)
            path = inputs_dir / (resource["id"] + ".bin")
            atomic_bytes(path, data)
            resources.append({"id": resource["id"], "use": resource.get("use", "context"),
                              "source": resource.get("path", resource.get("url")), "snapshot": str(path),
                              "sha256": sha(data), "bytes": len(data)})
        manifest = {"version": 1, "captured_at": now(), "policy_digest": self.policy_digest,
                    "runner_sha256": self.policy["runner_sha256"],
                    "request_key": self.request_key, "request": self.request, "inputs": resources}
        raw = encoded(manifest)
        atomic_bytes(self.directory / "manifest.json", raw)
        self.state["manifest_digest"] = sha(raw)
        plan = self.get_plan("prepare")
        atomic_json(self.directory / "plan.json", plan)
        self.state.update(phase="prepared", plan_digest=plan["digest"], plan_file_digest=sha(encoded(plan)), prepared_at=now())
        self.save()
        return self.view()

    def inspect_run(self):
        runs = Path(self.policy["workspace"]) / ".mentu/runs"
        request_hash = sha(self.request_key.encode())
        receipt_path = runs / ".admission" / (request_hash + ".json")
        receipt_raw = read_bytes(receipt_path)
        receipt = parse(receipt_raw)
        if (receipt.get("version") != 1 or receipt.get("digest") != self.state["plan_digest"] or
            receipt.get("operation") != "run" or receipt.get("requestHash") != request_hash or
            not RUN_ID.fullmatch(str(receipt.get("runId", "")))):
            raise Refused("runner_receipt_mismatch")
        directory = runs / receipt["runId"]
        admission = parse(read_bytes(directory / "admission.json"))
        plan = parse(read_bytes(directory / "plan.json"))
        if (admission.get("version") != 1 or admission.get("digest") != self.state["plan_digest"] or
            admission.get("parentRunId") is not None or plan.get("digest") != self.state["plan_digest"]):
            raise Refused("runner_admission_mismatch")
        if plan != self.frozen():
            raise Refused("runner_retained_plan_mismatch")
        raw = read_bytes(directory / "run.json")
        record = parse(raw)
        steps = record.get("steps")
        if record.get("run_id") != receipt["runId"] or record.get("outcome") not in ("ok", "failed") or not record.get("ended_at") or not isinstance(steps, list):
            raise Refused("runner_not_terminal")
        if not steps or any(s.get("execution_unverifiable") is True or s.get("exit_code") == 124 or
                            s.get("outcome") in ("running", "unknown", "UNKNOWN") for s in steps):
            raise Refused("runner_execution_unverifiable")
        if record["outcome"] == "ok" and any(s.get("local_complete") is not True or s.get("exit_code") != 0 for s in steps):
            raise Refused("runner_success_contradiction")
        atomic_bytes(self.directory / "run-record.json", raw)
        atomic_bytes(self.directory / "runner-receipt.json", receipt_raw)
        return self.result("completed", outcome=record["outcome"], run_id=receipt["runId"],
                           plan_digest=self.state["plan_digest"], manifest=str(self.directory / "manifest.json"),
                           manifest_sha256=self.state["manifest_digest"],
                           run_record={"path": str(directory / "run.json"), "sha256": sha(raw),
                                       "snapshot": str(self.directory / "run-record.json")},
                           admission_receipt={"path": str(receipt_path), "sha256": sha(receipt_raw),
                                              "snapshot": str(self.directory / "runner-receipt.json")},
                           runner_exit_code=self.state.get("runner_exit_code"))

    def retained_result(self):
        raw = read_bytes(self.directory / "result.json", private=True)
        if sha(raw) != self.state["result_digest"]:
            raise Refused("retained_result_changed")
        result = parse(raw)
        if (result.get("request_key") != self.request_key or result.get("outcome") != self.state["outcome"] or
                result.get("run_id") != self.state["run_id"] or result.get("plan_digest") != self.state["plan_digest"]):
            raise Refused("retained_result_binding_mismatch")
        for field in ("run_record", "admission_receipt"):
            if sha(read_bytes(Path(result[field]["snapshot"]), private=True)) != result[field]["sha256"]:
                raise Refused("retained_run_evidence_changed")
        self.frozen()
        return raw

    def report(self):
        raw = self.retained_result()
        reporter = self.policy["reporter"]
        code, error = self.process(reporter["argv"], "report", reporter["timeout_seconds"], raw)
        evidence = None
        if not error and code == 0:
            try:
                response = parse(read_bytes(self.directory / "report.stdout", 65536, private=True))
                exact(response, {"evidence"})
                if text_value(response["evidence"]):
                    evidence = response["evidence"]
            except Refused:
                pass
        if not evidence:
            self.state.update(phase="report_pending", report_error="reporter_receipt_unavailable", report_attempted_at=now())
            self.save()
            return self.view()
        self.state.update(phase="reported", evidence=evidence, reported_at=now())
        self.state.pop("report_error", None)
        self.save()  # This durable receipt, not printed output, permits consumer ack.
        return self.view()

    def run(self, digest):
        if not isinstance(digest, str) or not HEX.fullmatch(digest) or digest != self.state.get("plan_digest"):
            raise Refused("reviewed_plan_digest_required")
        phase = self.state["phase"]
        if phase == "reported":
            return self.view()
        if phase == "report_pending":
            return self.report()
        if phase == "prepared":
            self.frozen()
            self.check_recipe()
            if self.get_plan("preflight")["digest"] != digest:
                raise Refused("plan_changed")
            self.check_runner()
            self.state.update(phase="launch_intent", launched_at=now())
            self.save()
            argv = self.command("run") + ["--plan-digest", digest, "--request-key", self.request_key]
            code, error = self.process(argv, "runner", self.policy.get("run_timeout_seconds", 300))
            self.state.update(runner_exit_code=code)
            if error:
                self.state.update(phase="unresolved", reason=error)
                self.save()
                return self.view()
            self.save()
        elif phase not in ("launch_intent", "unresolved"):
            raise Refused("prepare_required")
        # Also used after a lost parent. Inspect existing evidence only. Never
        # invoke the runner again from launch_intent or unresolved.
        try:
            result = self.inspect_run()
        except Refused as exc:
            self.state.update(phase="unresolved", reason=str(exc))
            self.save()
            return self.view()
        atomic_json(self.directory / "result.json", result)
        self.state.update(phase="report_pending", result_digest=sha(encoded(result)), outcome=result["outcome"], run_id=result["run_id"])
        self.save()
        return self.report()

    def view(self):
        phase = self.state["phase"]
        if phase == "reported":
            self.retained_result()
        result = self.result(phase, ack_eligible=phase == "reported")
        for key in ("plan_digest", "manifest_digest", "run_id", "outcome", "evidence", "reason", "report_error", "reported_at"):
            if key in self.state:
                result[key] = self.state[key]
        if phase == "reported":
            result["receipt"] = str(self.state_path)
        return result

    def execute(self, verb, digest=None):
        private_directory(Path(self.policy["journal_dir"]))
        private_directory(self.directory)
        with occurrence_lock(self.directory / "occurrence.lock") as acquired:
            if not acquired:
                return self.result("busy", ack_eligible=False), 3
            self.load()
            if verb == "prepare":
                result = self.prepare()
            elif verb == "run":
                result = self.run(digest)
            else:
                result = self.view()
            phase = result["disposition"]
            code = {"unresolved": 4, "launch_intent": 4, "report_pending": 5}.get(phase, 0)
            if phase == "reported" and result.get("outcome") != "ok":
                code = 10
            return result, code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("prepare", "run", "status"))
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--plan-digest")
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        if (args.command == "run") != bool(args.plan_digest):
            raise Refused("plan_digest_required_only_for_run")
        policy, request = load_policy(args.policy), load_request(args.request)
        result, code = Dispatch(policy, request).execute(args.command, args.plan_digest)
    except Refused as exc:
        result, code = {"version": 1, "disposition": "refused", "reason": str(exc), "ack_eligible": False}, 2
    except (OSError, KeyError, TypeError, AttributeError, RecursionError):
        result, code = {"version": 1, "disposition": "refused", "reason": "invalid_or_unavailable_local_state", "ack_eligible": False}, 2
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
