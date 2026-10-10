"""Hermetic MP HTTP/dispatch fixtures; no providers, real desks or credentials."""
import contextlib
import copy
import fcntl
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("continuity_monitor", Path(__file__).with_name("monitor.py"))
monitor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(monitor)


FAKE_DISPATCH = r'''
import hashlib, json, os, pathlib, sys
def encode(v):
    return (json.dumps(v, sort_keys=True, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
def sha(v): return hashlib.sha256(v).hexdigest()
args = sys.argv
p = json.loads(pathlib.Path(args[args.index("--policy") + 1]).read_text())
request = json.loads(pathlib.Path(args[args.index("--request") + 1]).read_text())
root = pathlib.Path(p["test_root"])
verb = args[1]
with (root / "calls").open("a") as f: f.write(verb + "\n")
if any("fixture-monitor-secret" in v for v in os.environ.values()):
    raise RuntimeError("consumer leaked bearer")
key = sha((p["namespace"] + "\0" + request["occurrence"]).encode())
directory = pathlib.Path(p["journal_dir"]) / key
directory.mkdir(mode=0o700, parents=True, exist_ok=True)
state_path = directory / "state.json"
state = json.loads(state_path.read_text()) if state_path.exists() else {
    "version": 1, "phase": "prepared", "plan_digest": "a" * 64,
    "request_key": "continuity:" + key,
    "request_digest": sha(encode(request)), "policy_digest": sha(encode(p))}
if verb == "run":
    assert args[args.index("--plan-digest") + 1] == "a" * 64
    if state["phase"] == "prepared":
        with (root / "executions").open("a") as f: f.write(request["occurrence"] + "\n")
        state["phase"] = "report_pending"
    if not (root / "fail_report").exists():
        state.update(phase="reported", evidence="desk:fixture#report-1", outcome="ok", run_id="run_fixture")
state_path.write_bytes(encode(state))
state_path.chmod(0o600)
if (root / "forge_receipt").exists():
    state["phase"] = "reported" # stdout lies; the durable file disagrees
result = dict(state, disposition=state["phase"], ack_eligible=state["phase"] == "reported",
              receipt=str(state_path))
print(json.dumps(result))
sys.exit(5 if state["phase"] == "report_pending" else 0)
'''


def event():
    return {"specversion": "1.0", "id": "event-1", "source": "monitor:fixture",
            "type": "ai.mentu.test.work", "subject": "desk:fixture#ask-1", "time": "2026-10-10T00:00:00Z",
            "sequence": "00000000000000000001", "tier": "src", "origin": "system", "verified": "reported",
            "horizon": "event", "actor": "system:fixture", "data": {"provenance": {
                "origin": "system", "tier": "src", "verification": "reported", "actor": "system:fixture",
                "source_ref": "desk:fixture#ask-1"}}}


class FakeMP:
    def __init__(self):
        self.event, self.cursor, self.head, self.floor = event(), 0, 1, 1
        self.acks, self.pulls, self.received = [], 0, []
        self.ack_failure, self.lost_ack, self.redirect, self.forced_duplicate = False, False, False, False
        self.page_override = {}
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self, value, code=200):
                raw = json.dumps(value).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                fixture.received.append((self.path, self.headers.get("Authorization")))
                fixture.pulls += 1
                if fixture.redirect:
                    self.send_response(302)
                    self.send_header("Location", "/forbidden-redirect")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                pending = fixture.cursor < 2 or fixture.forced_duplicate
                page = {"subscription": "sub-fixture", "cursor": 0 if fixture.forced_duplicate else fixture.cursor,
                        "next": 2, "head": fixture.head, "retention_floor": fixture.floor,
                        "observations": [copy.deepcopy(fixture.event)] if pending else []}
                page.update(fixture.page_override)
                self.respond(page)

            def do_POST(self):
                fixture.received.append((self.path, self.headers.get("Authorization")))
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                fixture.acks.append(body["cursor"])
                if fixture.lost_ack:
                    fixture.cursor = body["cursor"]
                    self.respond({"error": "lost"}, 503)
                elif fixture.ack_failure:
                    self.respond({"error": "temporary"}, 503)
                else:
                    fixture.cursor = body["cursor"]
                    self.respond({"subscription": "sub-fixture", "cursor": fixture.cursor})

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:%s" % self.server.server_port

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.mp = FakeMP()
        self.fake = self.root / "dispatch.py"
        self.fake.write_text(FAKE_DISPATCH)
        self.policy = {"version": 1, "namespace": "routine-fixture", "journal_dir": str(self.root / "dispatch-journal"),
                       "inherit_env": ["HOME", "TEST_TOKEN_ALIAS"], "inputs": [], "test_root": str(self.root),
                       "reporter": {"timeout_seconds": 1}, "run_timeout_seconds": 1, "plan_timeout_seconds": 1}
        self.policy_path = self.root / "policy.json"
        monitor.save(self.policy_path, self.policy)
        self.token_path = self.root / "token"
        self.token_path.write_text("fixture-monitor-secret\n")
        self.token_path.chmod(0o600)
        self.config = {"version": 1, "base_url": self.mp.url, "subscription": "sub-fixture",
                       "token_file": str(self.token_path), "journal_dir": str(self.root / "monitor-journal"),
                       "policy": {"path": str(self.policy_path), "sha256": monitor.sha(self.policy_path.read_bytes())},
                       "standing_authorization": True, "allowed_source": "monitor:fixture",
                       "allowed_type": "ai.mentu.test.work", "work_ref": "desk:fixture#ask-1", "work_ref_field": "subject"}
        self.config_path = self.root / "config.json"
        monitor.save(self.config_path, self.config)
        self.dispatch_patch = patch.object(monitor, "DISPATCH", self.fake)
        self.dispatch_patch.start()
        self.env_patch = patch.dict(os.environ, {"TEST_TOKEN_ALIAS": "fixture-monitor-secret"})
        self.env_patch.start()

    def tearDown(self):
        self.env_patch.stop()
        self.dispatch_patch.stop()
        self.mp.close()
        self.temp.cleanup()

    def once(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = monitor.main(["once", "--config", str(self.config_path)])
        return code, json.loads(out.getvalue())

    def lines(self, name):
        path = self.root / name
        return path.read_text().splitlines() if path.exists() else []

    def assert_refused_without_dispatch(self, reason=None):
        code, result = self.once()
        self.assertEqual(code, 2, result)
        if reason:
            self.assertEqual(result["reason"], reason)
        self.assertFalse(result["acknowledged"])
        self.assertEqual(self.lines("calls"), [])
        self.assertEqual(self.mp.acks, [])

    def test_duplicate_with_redelivered_metadata_executes_once(self):
        code, first = self.once()
        self.assertEqual(code, 0, first)
        self.assertTrue(first["acknowledged"])
        self.mp.forced_duplicate = True
        self.mp.event["redelivered"] = True
        code, duplicate = self.once()
        self.assertEqual(code, 0, duplicate)
        self.assertEqual(first["occurrence"], duplicate["occurrence"])
        self.assertEqual(len(self.lines("executions")), 1)
        self.assertEqual(self.lines("calls"), ["prepare", "run"])
        self.assertEqual(self.mp.acks, [2, 2])
        self.assertTrue(all(auth == "Bearer fixture-monitor-secret" for _, auth in self.mp.received))
        self.assertTrue(all("limit=1" in path for path, _ in self.mp.received if "/pull" in path))

    def test_failed_report_stays_unacked_then_retries_report_only(self):
        failure = self.root / "fail_report"
        failure.touch()
        code, result = self.once()
        self.assertEqual(code, 4, result)
        self.assertEqual(result["dispatch_disposition"], "report_pending")
        self.assertEqual(self.mp.acks, [])
        failure.unlink()
        self.assertEqual(self.once()[0], 0)
        self.assertEqual(len(self.lines("executions")), 1)
        self.assertEqual(self.mp.acks, [2])

    def test_ack_failure_reuses_durable_receipt_without_dispatch(self):
        self.mp.ack_failure = True
        self.assertEqual(self.once()[0], 4)
        calls = self.lines("calls")
        self.mp.ack_failure = False
        self.assertEqual(self.once()[0], 0)
        self.assertEqual(self.lines("calls"), calls)
        self.assertEqual(len(self.lines("executions")), 1)
        self.assertEqual(self.mp.acks, [2, 2])

    def test_ack_committed_but_response_lost_reconciles_cursor(self):
        self.mp.lost_ack = True
        self.assertEqual(self.once()[0], 4)
        calls = self.lines("calls")
        self.mp.lost_ack = False
        code, result = self.once()
        self.assertEqual(code, 0, result)
        self.assertTrue(result["recovered_ack"])
        self.assertEqual(self.lines("calls"), calls)
        self.assertEqual(self.mp.acks, [2])

    def test_identity_conflict_after_ack_is_refused(self):
        self.assertEqual(self.once()[0], 0)
        self.mp.forced_duplicate = True
        self.mp.event["data"]["changed"] = True
        code, result = self.once()
        self.assertEqual(code, 2, result)
        self.assertEqual(result["reason"], "observation_identity_conflict")
        self.assertEqual(len(self.lines("executions")), 1)
        self.assertEqual(self.mp.acks, [2])

    def test_different_outstanding_event_is_refused(self):
        (self.root / "fail_report").touch()
        self.assertEqual(self.once()[0], 4)
        self.mp.event["id"] = "different"
        code, result = self.once()
        self.assertEqual(code, 2, result)
        self.assertEqual(result["reason"], "pending_delivery_changed")
        self.assertEqual(len(self.lines("executions")), 1)

    def test_policy_byte_drift_fails_before_pull(self):
        self.policy_path.write_bytes(self.policy_path.read_bytes() + b" ")
        self.assert_refused_without_dispatch("policy_digest_mismatch")
        self.assertEqual(self.mp.pulls, 0)

    def test_redirect_never_followed(self):
        self.mp.redirect = True
        self.assert_refused_without_dispatch("mp_redirect_refused")
        self.assertEqual(len(self.mp.received), 1)

    def test_rejected_type(self):
        self.mp.event["type"] = "ai.mentu.other"
        self.assert_refused_without_dispatch("event_not_authorized")

    def test_rejected_work_ref(self):
        self.mp.event["subject"] = "desk:fixture#unapproved"
        self.assert_refused_without_dispatch("work_reference_not_authorized")

    def test_source_ref_mapping(self):
        self.config["work_ref_field"] = "source_ref"
        monitor.save(self.config_path, self.config)
        self.mp.event["subject"] = "not-the-work-ref"
        self.assertEqual(self.once()[0], 0)

    def test_retention_gap_is_not_reset(self):
        self.mp.floor = 2
        self.assert_refused_without_dispatch("mp_retention_gap_no_reset")

    def test_cursor_must_be_safe_integer_and_match_sequence(self):
        for override in ({"cursor": True}, {"head": 2**53}, {"next": 3}):
            with self.subTest(override=override):
                self.mp.page_override = override
                self.assert_refused_without_dispatch()

    def test_cloud_event_schema_rejects_missing_and_invalid_fields(self):
        original = event()
        mutations = [("specversion", "0.3"), ("horizon", "forever"), ("sequence", "1"),
                     ("redelivered", "true"), ("data", {})]
        for field, value in mutations:
            with self.subTest(field=field):
                self.mp.event = copy.deepcopy(original)
                self.mp.event[field] = value
                self.assert_refused_without_dispatch()

    def test_stdout_report_without_durable_receipt_does_not_ack(self):
        (self.root / "forge_receipt").touch()
        code, result = self.once()
        self.assertEqual(code, 2, result)
        self.assertEqual(result["reason"], "dispatch_receipt_not_durable_or_bound")
        self.assertEqual(self.mp.acks, [])

    def test_foreign_cursor_advance_is_not_silently_accepted(self):
        self.assertEqual(self.once()[0], 0)
        self.mp.cursor = 3
        code, result = self.once()
        self.assertEqual(code, 2, result)
        self.assertEqual(result["reason"], "subscription_cursor_advanced_without_receipt")

    def test_changed_durable_receipt_after_ack_failure_is_refused(self):
        self.mp.ack_failure = True
        self.assertEqual(self.once()[0], 4)
        path = next((self.root / "dispatch-journal").glob("*/state.json"))
        path.write_bytes(path.read_bytes() + b" ")
        self.mp.ack_failure = False
        code, result = self.once()
        self.assertEqual(code, 2, result)
        self.assertEqual(result["reason"], "consumer_receipt_changed")
        self.assertEqual(self.mp.acks, [2])

    def test_truncated_response_is_retryable_without_cursor_reset(self):
        with patch.object(monitor.urllib.request.OpenerDirector, "open", side_effect=monitor.http.client.IncompleteRead(b"{", 10)):
            code, result = self.once()
        self.assertEqual(code, 4, result)
        self.assertEqual(result["reason"], "mp_unavailable")
        self.assertEqual(self.mp.acks, [])

    def test_private_config_and_explicit_authorization(self):
        self.config_path.chmod(0o644)
        self.assert_refused_without_dispatch("private_owned_file_required")
        self.config_path.chmod(0o600)
        self.config["standing_authorization"] = False
        monitor.save(self.config_path, self.config)
        self.assert_refused_without_dispatch("explicit_standing_authorization_required")

    def test_non_loopback_http_is_refused(self):
        self.config["base_url"] = "http://example.com"
        monitor.save(self.config_path, self.config)
        self.assert_refused_without_dispatch("https_or_loopback_required")

    def test_exclusive_consumer_lock(self):
        config, policy, token = monitor.configuration(self.config_path)
        consumer = monitor.Consumer(config, policy, token)
        with monitor.lock(consumer.directory / "consumer.lock") as acquired:
            self.assertTrue(acquired)
            code, result = self.once()
            self.assertEqual(code, 3, result)
            self.assertEqual(self.mp.pulls, 0)


if __name__ == "__main__":
    unittest.main()
