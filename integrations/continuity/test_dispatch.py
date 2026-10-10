"""Isolated boundary tests. Fake executables, temporary workspaces, no providers."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


MODULE = Path(__file__).with_name("dispatch.py")
SPEC = importlib.util.spec_from_file_location("continuity_dispatch", MODULE)
dispatch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dispatch)


RUNNER = r'''
import hashlib, json, os, pathlib, sys
root = pathlib.Path(os.environ['CONTINUITY_TEST_ROOT'])
args = sys.argv[1:]
verb, recipe = args[:2]
opts = {}; variables = {}
for i in range(2, len(args), 2):
    if args[i] == '--var':
        k,v = args[i+1].split('=',1); variables[k] = v
    else: opts[args[i]] = args[i+1]
with (root/'runner-calls.jsonl').open('a') as f:
    f.write(json.dumps({'verb':verb,'args':args})+'\n')
workspace = pathlib.Path(opts['--workspace'])
prompt = (root/'prompt.txt').read_text()
digest = hashlib.sha256(json.dumps({'recipe':pathlib.Path(recipe).read_text(),
    'prompt':prompt,'vars':variables,'backend':opts['--backend'],'model':opts['--model']},sort_keys=True).encode()).hexdigest()
plan = {'version':1,'digest':digest,'recipe':'test','source':recipe,'workspace':str(workspace),
        'steps':[{'label':'one','backend':opts['--backend'],'model':opts['--model'],'digest':digest}],
        'children':[],'unboundEnvironment':[]}
mode = json.loads((root/'mode.json').read_text()) if (root/'mode.json').exists() else {}
if verb == 'plan':
    if mode.get('plan_backend'): plan['steps'][0]['backend'] = mode['plan_backend']
    print(json.dumps(plan)); sys.exit(0)
assert verb == 'run'
manifest = pathlib.Path(variables['CONTINUITY_MANIFEST'])
assert json.loads((manifest.parent/'state.json').read_text())['phase'] == 'launch_intent'
assert hashlib.sha256(manifest.read_bytes()).hexdigest() == variables['CONTINUITY_MANIFEST_SHA256']
assert digest == opts['--plan-digest']
if mode.get('run') == 'slow':
    import time; time.sleep(10)
if mode.get('run') == 'empty': sys.exit(0)
run_id = 'run_fixture'
runs = workspace/'.mentu/runs'; run = runs/run_id
run.mkdir(parents=True, exist_ok=True); (runs/'.admission').mkdir(exist_ok=True)
keyhash = hashlib.sha256(opts['--request-key'].encode()).hexdigest()
(runs/'.admission'/f'{keyhash}.json').write_text(json.dumps({'version':1,'digest':digest,
    'operation':'run','runId':run_id,'requestHash':keyhash}))
(run/'admission.json').write_text(json.dumps({'version':1,'digest':digest}))
(run/'plan.json').write_text(json.dumps(plan))
outcome = mode.get('run', 'ok')
record = {'run_id':run_id,'outcome':outcome if outcome in ('running','failed') else 'ok',
    'started_at':'2026-01-01T00:00:00Z','ended_at':None if outcome=='running' else '2026-01-01T00:00:01Z',
    'steps':[{'label':'one','backend':opts['--backend'],'model':opts['--model'],
    'exit_code':1 if outcome=='failed' else 0,'local_complete':outcome!='failed',
    'execution_unverifiable':outcome=='unverifiable'}]}
(run/'run.json').write_text(json.dumps(record))
print('A fake runner completed; this line is not the authoritative result.')
sys.exit(1 if outcome=='failed' else 0)
'''


REPORTER = r'''
import json, os, pathlib, sys
root = pathlib.Path(os.environ['CONTINUITY_TEST_ROOT'])
value = json.load(sys.stdin)
with (root/'reporter-calls.jsonl').open('a') as f: f.write(json.dumps(value)+'\n')
mode = json.loads((root/'mode.json').read_text()) if (root/'mode.json').exists() else {}
database = root/'external-reports.json'
records = json.loads(database.read_text()) if database.exists() else {}
evidence = records.setdefault(value['request_key'], 'test:report:1')
database.write_text(json.dumps(records))
if mode.get('report') == 'fail': sys.exit(1)
print(json.dumps({'evidence':evidence}))
'''


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="continuity-dispatch-test-")
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        recipes = self.workspace / ".mentu/recipes"
        recipes.mkdir(parents=True)
        self.recipe = recipes / "test.json"
        self.recipe.write_text('{"name":"test","steps":[{"label":"one","prompt":"Read $CONTINUITY_MANIFEST"}]}')
        self.runner = self.root / "runner"
        self.runner.write_text("#!" + sys.executable + "\n" + RUNNER)
        self.runner.chmod(0o700)
        self.reporter = self.root / "reporter.py"
        self.reporter.write_text(REPORTER)
        (self.root / "prompt.txt").write_text("Fixed reviewed prompt.")
        self.input = self.root / "context.txt"
        self.input.write_bytes(b"Pinned observation, not authority.\n")
        self.policy = {
            "version": 1, "namespace": "isolated-test", "runner": str(self.runner),
            "runner_sha256": dispatch.file_sha(self.runner), "workspace": str(self.workspace),
            "recipe": {"path": str(self.recipe), "sha256": dispatch.file_sha(self.recipe)},
            "backend": "codex", "model": "test-model", "journal_dir": str(self.root / "journal"),
            "manifest_var": "CONTINUITY_MANIFEST", "inherit_env": ["PATH", "HOME", "CONTINUITY_TEST_ROOT"],
            "inputs": [{"id": "observation", "path": str(self.input), "sha256": dispatch.file_sha(self.input),
                        "max_bytes": 4096, "timeout_seconds": 2}],
            "reporter": {"argv": [sys.executable, str(self.reporter)], "timeout_seconds": 5},
            "plan_timeout_seconds": 5, "run_timeout_seconds": 5,
        }
        self.request = {"version": 1, "occurrence": "occurrence-1", "work_ref": "test:work:1", "trigger_ref": "test:event:1"}
        self.policy_path, self.request_path = self.root / "policy.json", self.root / "request.json"
        self.write_config()
        self.environment = patch.dict(os.environ, {"CONTINUITY_TEST_ROOT": str(self.root)})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temporary.cleanup()

    def write_config(self):
        self.policy_path.write_text(json.dumps(self.policy)); self.policy_path.chmod(0o600)
        self.request_path.write_text(json.dumps(self.request)); self.request_path.chmod(0o600)

    def invoke(self, command, digest=None):
        argv = [command, "--policy", str(self.policy_path), "--request", str(self.request_path)]
        if digest is not None: argv += ["--plan-digest", digest]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = dispatch.main(argv)
        return code, json.loads(out.getvalue())

    def prepare(self):
        code, value = self.invoke("prepare")
        self.assertEqual(code, 0, value)
        self.assertEqual(value["disposition"], "prepared")
        return value

    def mode(self, **values):
        (self.root / "mode.json").write_text(json.dumps(values))

    def calls(self, which="runner", verb=None):
        path = self.root / (which + "-calls.jsonl")
        values = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [v for v in values if verb is None or v.get("verb") == verb]

    def test_frozen_prepare_and_duplicate_reported_run(self):
        prepared = self.prepare()
        directory = Path(prepared["journal"])
        manifest = (directory / "manifest.json").read_bytes()
        self.input.write_text("The current source changed; this occurrence retains its snapshot.")
        again = self.prepare()
        self.assertEqual(prepared, again)
        self.assertEqual(manifest, (directory / "manifest.json").read_bytes())
        self.assertEqual(len(self.calls(verb="plan")), 1)
        code, result = self.invoke("run", prepared["plan_digest"])
        self.assertEqual(code, 0, result)
        self.assertEqual(result["disposition"], "reported")
        self.assertTrue(result["ack_eligible"])
        self.assertEqual(result["evidence"], "test:report:1")
        state = json.loads(Path(result["receipt"]).read_text())
        self.assertEqual(state["phase"], "reported")
        _, duplicate = self.invoke("run", prepared["plan_digest"])
        self.assertEqual(result, duplicate)
        self.assertEqual(len(self.calls(verb="run")), 1)
        self.assertEqual(len(self.calls("reporter")), 1)
        self.assertEqual(self.invoke("status")[1], result)

    def test_request_or_policy_conflict_never_reexecutes(self):
        prepared = self.prepare()
        self.request["work_ref"] = "test:work:other"; self.write_config()
        self.assertEqual(self.invoke("prepare")[1]["reason"], "occurrence_conflict")
        self.request["work_ref"] = "test:work:1"
        self.policy["model"] = "other-model"; self.write_config()
        self.assertEqual(self.invoke("run", prepared["plan_digest"])[1]["reason"], "occurrence_conflict")
        self.assertEqual(len(self.calls(verb="run")), 0)

    def test_unknown_request_fields_cannot_select_url_prompt_command_or_credentials(self):
        for field in ("url", "prompt", "command", "credential", "backend"):
            with self.subTest(field=field):
                self.request[field] = "https://unapproved.invalid/input"
                self.write_config()
                code, result = self.invoke("prepare")
                self.assertEqual(code, 2)
                self.assertEqual(result["reason"], "unsupported_or_missing_fields")
                del self.request[field]
        self.assertEqual(len(self.calls()), 0)

    def test_launch_intent_crash_refuses_repeat_without_runner_evidence(self):
        prepared = self.prepare()
        path = Path(prepared["journal"]) / "state.json"
        state = json.loads(path.read_text()); state["phase"] = "launch_intent"
        dispatch.atomic_json(path, state)
        for _ in range(2):
            code, result = self.invoke("run", prepared["plan_digest"])
            self.assertEqual(code, 4)
            self.assertEqual(result["disposition"], "unresolved")
            self.assertFalse(result["ack_eligible"])
        self.assertEqual(len(self.calls(verb="run")), 0)

    def test_lost_parent_reconciles_existing_terminal_run_without_launching_again(self):
        prepared = self.prepare()
        instance = dispatch.Dispatch(self.policy, self.request)
        instance.load()
        instance.state["phase"] = "launch_intent"; instance.save()
        code, error = instance.process(instance.command("run") + ["--plan-digest", prepared["plan_digest"],
                                      "--request-key", instance.request_key], "fixture", 5)
        self.assertEqual((code, error), (0, None))
        code, result = self.invoke("run", prepared["plan_digest"])
        self.assertEqual(code, 0, result)
        self.assertEqual(len(self.calls(verb="run")), 1)
        self.assertEqual(len(self.calls("reporter")), 1)

    def test_failed_report_retries_same_result_after_external_write_without_model_repeat(self):
        prepared = self.prepare(); self.mode(report="fail")
        code, first = self.invoke("run", prepared["plan_digest"])
        self.assertEqual(code, 5)
        self.assertEqual(first["disposition"], "report_pending")
        self.assertFalse(first["ack_eligible"])
        self.mode()
        code, result = self.invoke("run", prepared["plan_digest"])
        self.assertEqual(code, 0, result)
        self.assertEqual(len(self.calls(verb="run")), 1)
        self.assertEqual(len(self.calls("reporter")), 2)
        self.assertEqual(self.calls("reporter")[0], self.calls("reporter")[1])
        self.assertEqual(len(json.loads((self.root / "external-reports.json").read_text())), 1)

    def test_exit_zero_without_terminal_evidence_is_never_reported(self):
        for mode in ("empty", "running", "unverifiable"):
            with self.subTest(mode=mode):
                self.request["occurrence"] = mode; self.write_config()
                prepared = self.prepare(); self.mode(run=mode)
                code, result = self.invoke("run", prepared["plan_digest"])
                self.assertEqual(code, 4, result)
                self.assertEqual(result["disposition"], "unresolved")
                self.assertFalse(result["ack_eligible"])
        self.assertEqual(len(self.calls("reporter")), 0)

    def test_terminal_failure_reports_failure_without_claiming_success(self):
        prepared = self.prepare(); self.mode(run="failed")
        code, result = self.invoke("run", prepared["plan_digest"])
        self.assertEqual(code, 10)
        self.assertEqual(result["disposition"], "reported")
        self.assertEqual(result["outcome"], "failed")
        self.assertEqual(self.calls("reporter")[0]["runner_exit_code"], 1)

    def test_runner_timeout_is_unresolved_and_never_automatically_repeated(self):
        self.policy["run_timeout_seconds"] = 1; self.write_config()
        prepared = self.prepare(); self.mode(run="slow")
        code, result = self.invoke("run", prepared["plan_digest"])
        self.assertEqual(code, 4)
        self.assertEqual(result["disposition"], "unresolved")
        self.assertFalse(result["ack_eligible"])
        self.assertEqual(result["reason"], "process_interrupted_or_timed_out")
        self.mode()
        self.assertEqual(self.invoke("run", prepared["plan_digest"])[0], 4)
        self.assertEqual(len(self.calls(verb="run")), 1)
        self.assertEqual(len(self.calls("reporter")), 0)

    def test_incomplete_receipt_or_modified_result_cannot_be_ack_eligible(self):
        prepared = self.prepare()
        code, result = self.invoke("run", prepared["plan_digest"])
        self.assertEqual(code, 0, result)
        state_path = Path(result["receipt"])
        original = state_path.read_bytes()
        state = json.loads(original); del state["evidence"]
        dispatch.atomic_json(state_path, state)
        code, invalid = self.invoke("status")
        self.assertEqual(code, 2)
        self.assertFalse(invalid["ack_eligible"])
        self.assertEqual(invalid["reason"], "incomplete_report_receipt")
        dispatch.atomic_bytes(state_path, original)
        (Path(result["journal"]) / "run-record.json").write_text("{}")
        code, invalid = self.invoke("status")
        self.assertEqual(code, 2)
        self.assertFalse(invalid["ack_eligible"])
        self.assertEqual(invalid["reason"], "retained_run_evidence_changed")

    def test_wrong_reviewed_digest_and_prompt_drift_refused_before_launch(self):
        prepared = self.prepare()
        self.assertEqual(self.invoke("run", "0" * 64)[1]["reason"], "reviewed_plan_digest_required")
        (self.root / "prompt.txt").write_text("Changed prompt.")
        code, result = self.invoke("run", prepared["plan_digest"])
        self.assertEqual(code, 2)
        self.assertEqual(result["reason"], "plan_changed")
        self.assertEqual(len(self.calls(verb="run")), 0)

    def test_recipe_runner_and_retained_input_drift_refused(self):
        prepared = self.prepare()
        self.recipe.write_text("changed")
        self.assertEqual(self.invoke("run", prepared["plan_digest"])[1]["reason"], "recipe_digest_mismatch")
        self.recipe.write_text('{"name":"test","steps":[{"label":"one","prompt":"Read $CONTINUITY_MANIFEST"}]}')
        original = self.runner.read_bytes(); self.runner.write_bytes(original + b"\n# changed\n")
        self.assertEqual(self.invoke("run", prepared["plan_digest"])[1]["reason"], "runner_digest_mismatch")
        self.runner.write_bytes(original)
        (Path(prepared["journal"]) / "inputs/observation.bin").write_text("changed")
        self.assertEqual(self.invoke("run", prepared["plan_digest"])[1]["reason"], "retained_input_changed")
        self.assertEqual(len(self.calls(verb="run")), 0)

    def test_manifest_drift_refused(self):
        prepared = self.prepare()
        (Path(prepared["journal"]) / "manifest.json").write_text("{}")
        self.assertEqual(self.invoke("run", prepared["plan_digest"])[1]["reason"], "retained_manifest_changed")

    def test_pinned_input_required_and_public_policy_refused(self):
        self.input.write_text("Changed before prepare.")
        self.assertEqual(self.invoke("prepare")[1]["reason"], "input_digest_mismatch")
        self.policy_path.chmod(0o644)
        self.assertEqual(self.invoke("prepare")[1]["reason"], "private_owned_file_required")

    def test_parallel_invocation_observes_occurrence_lock(self):
        prepared = self.prepare()
        with dispatch.occurrence_lock(Path(prepared["journal"]) / "occurrence.lock") as acquired:
            self.assertTrue(acquired)
            code, result = self.invoke("run", prepared["plan_digest"])
        self.assertEqual(code, 3)
        self.assertEqual(result["disposition"], "busy")
        self.assertEqual(len(self.calls(verb="run")), 0)

    def test_plan_provider_override_refused(self):
        self.mode(plan_backend="claude")
        code, result = self.invoke("prepare")
        self.assertEqual(code, 2)
        self.assertEqual(result["reason"], "plan_backend_or_model_mismatch")

    def test_https_exact_binding_auth_not_retained_and_no_redirect(self):
        data = b"Pinned cloud prompt"
        resource = {"id": "cloud", "url": "https://approved.example/prompt", "sha256": dispatch.sha(data),
                    "max_bytes": 4096, "timeout_seconds": 2, "auth_env": "CONTINUITY_FETCH_TOKEN", "use": "authorized_prompt"}
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def geturl(self): return resource["url"]
            def read(self, limit): return data
        class Opener:
            def open(self, request, timeout):
                self_test.assertEqual(request.full_url, resource["url"])
                self_test.assertEqual(request.headers["Authorization"], "Bearer not-a-real-token")
                self_test.assertEqual(timeout, 2)
                return Response()
        self_test = self
        self.policy["inputs"] = [resource]; self.write_config()
        with patch.dict(os.environ, {"CONTINUITY_FETCH_TOKEN": "not-a-real-token"}), \
             patch.object(dispatch.urllib.request, "build_opener", return_value=Opener()):
            prepared = self.prepare()
        directory = Path(prepared["journal"])
        self.assertEqual((directory / "inputs/cloud.bin").read_bytes(), data)
        self.assertEqual(json.loads((directory / "manifest.json").read_text())["inputs"][0]["use"], "authorized_prompt")
        for path in directory.rglob("*"):
            if path.is_file(): self.assertNotIn(b"not-a-real-token", path.read_bytes())
        with self.assertRaisesRegex(dispatch.Refused, "input_redirect_refused"):
            dispatch.NoRedirect().redirect_request(None, None, 302, None, None, "https://other.example")
        self.policy["inputs"][0]["url"] = "http://approved.example/prompt"; self.write_config()
        self.assertEqual(self.invoke("prepare")[1]["reason"], "exact_https_input_required")

    def test_resolver_wall_timeout_leaves_no_child(self):
        def stalled(resource, connection):
            time.sleep(10)
        resource = dict(self.policy["inputs"][0], timeout_seconds=1)
        started = time.monotonic()
        with patch.object(dispatch, "fetch_worker", stalled):
            with self.assertRaisesRegex(dispatch.Refused, "input_fetch_timeout"):
                dispatch.fetch(resource)
        self.assertLess(time.monotonic() - started, 3)


if __name__ == "__main__":
    unittest.main()
