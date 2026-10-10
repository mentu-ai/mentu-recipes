#!/usr/bin/env python3
"""Consume at most one MP observation through the fixed sibling dispatch.py.

    python3 monitor.py once --config /private/monitor.json

Operator config (private file and parent): version=1, base_url, subscription,
token_file, journal_dir, policy={path,sha256}, standing_authorization=true,
allowed_source, allowed_type, work_ref, work_ref_field=subject|source_ref.
Optional request_timeout_seconds defaults to 5 (maximum 30).

The subscription MUST be dedicated to this consumer and all invocations MUST use
the same journal. A local flock excludes overlapping invocations; it cannot fence
another machine or another journal. Events select no commands, prompts, URLs,
credentials or policy. The explicit operator grant authorizes the pinned policy
for matching occurrences, including its pinned recipe and input resolution.

Only a durable dispatch reported receipt with ack_eligible=true permits a durable
consumer receipt and then an MP ack. Failed work can be reported and handled; this
does not accept the underlying work. Busy, refused, unresolved and report_pending
never ack. Redelivery retries reporting/reconciliation through dispatch, never an
alternative executor. Receipts survive lost ack responses. Nothing installs a
daemon, resets a cursor, creates a subscription or claims a distributed lease.

Exit codes: 0 idle/acknowledged, 2 refused, 3 busy, 4 pending/retry. JSON stdout.
POSIX and Python 3.10+. Same-UID processes are not an isolation boundary.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import http.client
import json
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


LIMIT = 2_000_000
SAFE_INTEGER = 2**53 - 1
HEX = re.compile(r"[a-f0-9]{64}\Z")
EVENT_TYPE = re.compile(r"[a-z0-9]+(?:\.[a-z0-9_-]+)+\Z")
SEQUENCE = re.compile(r"[0-9]{20}\Z")
ORIGINS = {"human", "agent", "webhook", "probe", "system"}
TIERS = {"src", "measured", "derived", "unverified", "falsified"}
VERIFIED = {"human_verified", "machine_verified", "certified", "reported", "unverified"}
HORIZONS = {"event", "minute", "hour", "day", "week", "month"}
DISPATCH = Path(__file__).resolve().with_name("dispatch.py")


class Refused(Exception):
    pass


class Retry(Exception):
    pass


def encoded(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def pairs(items):
    value = {}
    for key, item in items:
        if key in value:
            raise Refused("duplicate_json_key")
        value[key] = item
    return value


def parse(raw):
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise Refused("invalid_json") from exc


def text(value, maximum=2048):
    return isinstance(value, str) and 0 < len(value) <= maximum and not re.search(r"[\x00-\x20\x7f]", value)


def cursor(value):
    return type(value) is int and 0 <= value <= SAFE_INTEGER


def absolute(value):
    if not isinstance(value, str) or not value or not Path(value).is_absolute():
        raise Refused("absolute_path_required")
    return Path(value)


def private_dir(path, create=False):
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise Refused("private_owned_directory_required")


def read(path, limit=LIMIT):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(fd, "rb") as stream:
        st = os.fstat(stream.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise Refused("private_owned_file_required")
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise Refused("file_size_limit")
    return raw


def save(path, value):
    fd, name = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def base_url(value):
    if not isinstance(value, str) or re.search(r"[\x00-\x20\x7f]", value):
        raise Refused("invalid_mp_base")
    url = urllib.parse.urlsplit(value)
    if (not url.hostname or url.username or url.password or "?" in value or "#" in value or
            url.path.rstrip("/") not in ("", "/mp/v0")):
        raise Refused("invalid_mp_base")
    if url.scheme != "https" and not (url.scheme == "http" and url.hostname in ("localhost", "127.0.0.1", "::1")):
        raise Refused("https_or_loopback_required")
    _ = url.port  # validate the port before a request
    return urllib.parse.urlunsplit((url.scheme, url.netloc, "", "", ""))


def configuration(path):
    private_dir(path.parent)
    config = parse(read(path))
    required = {"version", "base_url", "subscription", "token_file", "journal_dir", "policy",
                "standing_authorization", "allowed_source", "allowed_type", "work_ref", "work_ref_field"}
    if not isinstance(config, dict) or not required <= config.keys() or config.keys() - required - {"request_timeout_seconds"}:
        raise Refused("invalid_config_fields")
    if type(config["version"]) is not int or config["version"] != 1 or config["standing_authorization"] is not True:
        raise Refused("explicit_standing_authorization_required")
    base_url(config["base_url"])
    if (not all(text(config[k], 1024) for k in ("subscription", "allowed_source", "allowed_type", "work_ref")) or
            config["subscription"] in (".", "..") or not EVENT_TYPE.fullmatch(config["allowed_type"]) or
            config["work_ref_field"] not in ("subject", "source_ref")):
        raise Refused("invalid_subscription_or_event_binding")
    for key in ("token_file", "journal_dir"):
        absolute(config[key])
    policy_pin = config["policy"]
    if not isinstance(policy_pin, dict) or set(policy_pin) != {"path", "sha256"} or not HEX.fullmatch(str(policy_pin["sha256"])):
        raise Refused("pinned_policy_required")
    policy_path = absolute(policy_pin["path"])
    private_dir(policy_path.parent)
    raw = read(policy_path)
    if sha(raw) != policy_pin["sha256"]:
        raise Refused("policy_digest_mismatch")
    policy = parse(raw)
    if (not isinstance(policy, dict) or not text(policy.get("namespace"), 128) or
            not isinstance(policy.get("inherit_env"), list) or not isinstance(policy.get("inputs"), list)):
        raise Refused("invalid_dispatch_policy")
    absolute(policy.get("journal_dir"))
    timeout = config.get("request_timeout_seconds", 5)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 0 < timeout <= 30:
        raise Refused("invalid_request_timeout")
    token = read(absolute(config["token_file"]), 16384).decode("utf-8").strip()
    if not token or "\r" in token or "\n" in token or any(ord(c) < 32 for c in token):
        raise Refused("invalid_bearer")
    return config, policy, token


@contextlib.contextmanager
def lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise Refused("private_owned_lock_required")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
        else:
            yield True
    finally:
        os.close(fd)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Refused("mp_redirect_refused")


@contextlib.contextmanager
def network_deadline(seconds):
    def expired(*_):
        raise Retry("mp_request_timeout")
    previous = signal.signal(signal.SIGALRM, expired)
    timer = signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, *timer)
        signal.signal(signal.SIGALRM, previous)


class Source:
    def __init__(self, config, token):
        self.config, self.token = config, token
        self.prefix = base_url(config["base_url"]) + "/mp/v0/subscriptions/" + urllib.parse.quote(config["subscription"], safe="")

    def request(self, action, body=None):
        url = self.prefix + "/" + action + ("?wait=0&limit=1" if action == "pull" else "")
        request = urllib.request.Request(url, data=encoded(body) if body is not None else None,
                                         headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        timeout = self.config.get("request_timeout_seconds", 5)
        try:
            with network_deadline(timeout), opener.open(request, timeout=timeout) as response:
                if response.geturl() != url or 300 <= response.status < 400:
                    raise Refused("mp_redirect_refused")
                length = response.headers.get("Content-Length")
                if length and (not length.isdecimal() or int(length) > LIMIT):
                    raise Refused("mp_response_size_limit")
                raw = response.read(LIMIT + 1)
                if len(raw) > LIMIT:
                    raise Refused("mp_response_size_limit")
        except urllib.error.HTTPError as exc:
            status = exc.code
            exc.close()
            if status in (408, 429) or status >= 500:
                raise Retry("mp_temporarily_unavailable") from exc
            raise Refused("mp_redirect_refused" if 300 <= status < 400 else "mp_request_refused") from exc
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError, http.client.HTTPException) as exc:
            raise Retry("mp_unavailable") from exc
        value = parse(raw)
        if not isinstance(value, dict) or value.get("subscription") != self.config["subscription"]:
            raise Refused("mp_subscription_mismatch")
        return value

    def pull(self):
        page = self.request("pull")
        if not all(cursor(page.get(k)) for k in ("cursor", "next", "head", "retention_floor")):
            raise Refused("mp_invalid_cursor")
        if page["retention_floor"] > max(page["cursor"], 1):
            raise Refused("mp_retention_gap_no_reset")
        observations = page.get("observations")
        if not isinstance(observations, list) or len(observations) > 1:
            raise Refused("mp_expected_at_most_one_observation")
        if not observations:
            return page, None
        event = observation(observations[0])
        seq = int(event["sequence"])
        if not cursor(seq) or not cursor(seq + 1) or page["next"] != seq + 1 or seq < page["cursor"] or seq > page["head"]:
            raise Refused("mp_sequence_cursor_mismatch")
        event.pop("redelivered", None)
        return page, event

    def ack(self, next_cursor):
        result = self.request("ack", {"cursor": next_cursor})
        if not cursor(result.get("cursor")) or result["cursor"] != next_cursor:
            raise Refused("mp_ack_cursor_mismatch")


def observation(raw):
    """Mirror MP observation.json's typed fields; extension keys remain open.

    As in MP's validator, URI/date-time formats are annotations. Routing below
    additionally requires a configured subject or source_ref. A base64 event can
    route by subject; no event payload is decoded or executed.
    """
    if not isinstance(raw, dict):
        raise Refused("mp_invalid_observation")
    event = dict(raw)
    required = {"specversion", "id", "source", "type", "time", "sequence", "tier", "origin", "verified", "horizon", "actor"}
    if (not required <= event.keys() or event["specversion"] != "1.0" or
            not all(isinstance(event[k], str) for k in required) or
            not text(event["source"]) or not text(event["id"]) or not EVENT_TYPE.fullmatch(event["type"]) or
            not SEQUENCE.fullmatch(event["sequence"])):
        raise Refused("mp_invalid_observation")
    for key, values in (("tier", TIERS), ("origin", ORIGINS), ("verified", VERIFIED), ("horizon", HORIZONS)):
        if event[key] not in values:
            raise Refused("mp_invalid_observation_vocabulary")
    for key in ("datacontenttype", "dataschema", "traceparent", "tracestate", "data_base64"):
        if key in event and not isinstance(event[key], str):
            raise Refused("mp_invalid_observation_field")
    if "subject" in event and event["subject"] is not None and not isinstance(event["subject"], str):
        raise Refused("mp_invalid_subject")
    if "redelivered" in event and type(event["redelivered"]) is not bool:
        raise Refused("mp_invalid_redelivered")
    if ("data" in event) == ("data_base64" in event):
        raise Refused("mp_exactly_one_data_encoding_required")
    if "data" in event:
        data = event["data"]
        if not isinstance(data, dict) or not isinstance(data.get("provenance"), dict):
            raise Refused("mp_provenance_required")
        p = data["provenance"]
        if (not {"origin", "tier", "verification", "actor"} <= p.keys() or
                p["origin"] not in ORIGINS or p["tier"] not in TIERS or p["verification"] not in VERIFIED or
                not isinstance(p["actor"], str)):
            raise Refused("mp_invalid_provenance")
        for key in ("source_ref", "rule", "on_behalf_of"):
            if key in p and p[key] is not None and not isinstance(p[key], str):
                raise Refused("mp_invalid_provenance_field")
        if "wasAttributedTo" in p and not isinstance(p["wasAttributedTo"], str):
            raise Refused("mp_invalid_provenance_field")
        if "attested" in p and type(p["attested"]) is not bool:
            raise Refused("mp_invalid_attestation")
        refs = p.get("wasDerivedFrom", [])
        if not isinstance(refs, list):
            raise Refused("mp_invalid_lineage")
        if p.get("supersedes") is not None:
            refs = refs + [p["supersedes"]]
        if any(not isinstance(r, dict) or not isinstance(r.get("source"), str) or not isinstance(r.get("id"), str) for r in refs):
            raise Refused("mp_invalid_lineage")
        if "tags" in data and not isinstance(data["tags"], dict):
            raise Refused("mp_invalid_tags")
    return event


class Consumer:
    def __init__(self, config, policy, token):
        self.config, self.policy, self.token = config, policy, token
        self.source = Source(config, token)
        self.journal = absolute(config["journal_dir"])
        private_dir(self.journal, create=True)
        self.config_digest = sha(encoded(config))
        identity = sha(encoded([base_url(config["base_url"]), config["subscription"]]))
        self.directory = self.journal / identity
        private_dir(self.directory, create=True)
        self.state_path = self.directory / "state.json"
        self.state = {"version": 1, "config_digest": self.config_digest, "pending": None}

    def persist(self):
        save(self.state_path, self.state)

    def policy_unchanged(self):
        if sha(read(Path(self.config["policy"]["path"]))) != self.config["policy"]["sha256"]:
            raise Refused("policy_digest_mismatch")

    def dispatch(self, verb, directory, plan=None):
        self.policy_unchanged()
        # The child receives only the policy's explicit credential allowlists.
        names = {"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"} | set(self.policy["inherit_env"])
        names |= {r["auth_env"] for r in self.policy["inputs"] if isinstance(r, dict) and "auth_env" in r}
        env = {k: os.environ[k] for k in names if k in os.environ and self.token not in os.environ[k]}
        argv = [sys.executable, "-B", str(DISPATCH), verb, "--policy", self.config["policy"]["path"],
                "--request", str(directory / "request.json")]
        if plan:
            argv += ["--plan-digest", plan]
        prepare_timeout = sum(r.get("timeout_seconds", 120) + 2 for r in self.policy["inputs"]) + self.policy.get("plan_timeout_seconds", 30) + 15
        run_timeout = self.policy.get("plan_timeout_seconds", 30) + self.policy.get("run_timeout_seconds", 300) + self.policy.get("reporter", {}).get("timeout_seconds", 300) + 15
        output = directory / (verb + ".stdout")
        errors = directory / (verb + ".stderr")
        out_fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        err_fd = os.open(errors, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(out_fd, "wb") as out, os.fdopen(err_fd, "wb") as err:
            child = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err)
            try:
                code = child.wait(timeout=prepare_timeout if verb == "prepare" else run_timeout)
            except subprocess.TimeoutExpired as exc:
                # Dispatch owns the runner process group and its timeout. Do not
                # kill its wrapper and strand a running child or claim no effect.
                raise Retry("dispatch_wait_expired_reconcile_before_retry") from exc
        result = parse(read(output, 65536))
        if not isinstance(result, dict) or result.get("version") != 1 or not isinstance(result.get("disposition"), str):
            raise Refused("invalid_dispatch_result")
        if code not in (0, 2, 3, 4, 5, 10):
            raise Retry("dispatch_interrupted")
        return result

    def handling_receipt(self, result, request, directory, fingerprint):
        if result.get("disposition") != "reported" or result.get("ack_eligible") is not True:
            raise Refused("reported_receipt_required")
        key = sha((self.policy["namespace"] + "\0" + request["occurrence"]).encode())
        receipt_path = Path(self.policy["journal_dir"]) / key / "state.json"
        if result.get("receipt") != str(receipt_path) or result.get("request_key") != "continuity:" + key:
            raise Refused("dispatch_receipt_binding_mismatch")
        raw = read(receipt_path)
        receipt = parse(raw)
        if (not isinstance(receipt, dict) or receipt.get("phase") != "reported" or
                receipt.get("request_key") != result["request_key"] or
                receipt.get("request_digest") != sha(encoded(request)) or
                receipt.get("policy_digest") != sha(encoded(self.policy)) or
                receipt.get("evidence") != result.get("evidence") or not text(receipt.get("evidence")) or
                receipt.get("plan_digest") != result.get("plan_digest") or
                not HEX.fullmatch(str(receipt.get("plan_digest", "")))):
            raise Refused("dispatch_receipt_not_durable_or_bound")
        value = {"version": 1, "fingerprint": fingerprint, "request": request,
                 "dispatch_receipt_sha256": sha(raw), "dispatch_receipt": str(receipt_path),
                 "request_key": result["request_key"], "evidence": result["evidence"],
                 "plan_digest": result["plan_digest"], "disposition": "reported", "ack_eligible": True,
                 "recorded_at": now()}
        save(directory / "handled.json", value)
        return value

    def retained_receipt(self, directory, request, fingerprint):
        receipt = parse(read(directory / "handled.json"))
        key = sha((self.policy["namespace"] + "\0" + request["occurrence"]).encode())
        expected = Path(self.policy["journal_dir"]) / key / "state.json"
        raw = read(expected)
        durable = parse(raw)
        if (not isinstance(receipt, dict) or receipt.get("fingerprint") != fingerprint or
                receipt.get("request") != request or receipt.get("disposition") != "reported" or
                receipt.get("ack_eligible") is not True or receipt.get("dispatch_receipt") != str(expected) or
                receipt.get("dispatch_receipt_sha256") != sha(raw) or not isinstance(durable, dict) or
                durable.get("phase") != "reported" or durable.get("request_key") != "continuity:" + key or
                durable.get("request_digest") != sha(encoded(request)) or
                durable.get("policy_digest") != sha(encoded(self.policy)) or
                not text(durable.get("evidence")) or not HEX.fullmatch(str(durable.get("plan_digest", ""))) or
                any(receipt.get(k) != durable.get(k) for k in ("request_key", "evidence", "plan_digest"))):
            raise Refused("consumer_receipt_changed")
        return receipt

    def once(self):
        with lock(self.directory / "consumer.lock") as acquired:
            if not acquired:
                return {"version": 1, "disposition": "busy", "acknowledged": False}, 3
            if self.state_path.exists():
                self.state = parse(read(self.state_path))
                if self.state.get("config_digest") != self.config_digest:
                    raise Refused("consumer_configuration_changed")
            self.policy_unchanged()
            page, event = self.source.pull()
            pending = self.state.get("pending")
            if not pending and "last_ack" in self.state and page["cursor"] > self.state["last_ack"]:
                raise Refused("subscription_cursor_advanced_without_receipt")
            if pending and page["cursor"] >= pending["next"]:
                if not pending.get("handled") or page["cursor"] != pending["next"]:
                    raise Refused("subscription_cursor_advanced_without_receipt")
                ident = pending["occurrence"].removeprefix("mp:")
                if not HEX.fullmatch(ident):
                    raise Refused("invalid_pending_identity")
                retained = self.directory / ident
                self.retained_receipt(retained, parse(read(retained / "request.json")), pending["fingerprint"])
                self.state.update(pending=None, last_ack=pending["next"])
                self.persist()
                return {"version": 1, "disposition": "acknowledged", "acknowledged": True,
                        "recovered_ack": True, "occurrence": pending["occurrence"]}, 0
            if event is None:
                if pending:
                    raise Refused("pending_delivery_missing")
                return {"version": 1, "disposition": "idle", "acknowledged": False}, 0
            if event["source"] != self.config["allowed_source"] or event["type"] != self.config["allowed_type"]:
                raise Refused("event_not_authorized")
            work_ref = event.get("subject") if self.config["work_ref_field"] == "subject" else (event.get("data") or {}).get("provenance", {}).get("source_ref")
            if work_ref != self.config["work_ref"]:
                raise Refused("work_reference_not_authorized")
            ident = sha(encoded([event["source"], event["id"]]))
            fingerprint = sha(encoded(event))
            occurrence = "mp:" + ident
            if pending and (pending["occurrence"] != occurrence or pending["fingerprint"] != fingerprint or pending["next"] != page["next"]):
                raise Refused("pending_delivery_changed")
            directory = self.directory / ident
            private_dir(directory, create=True)
            event_path = directory / "event.json"
            if event_path.exists() and sha(read(event_path)) != fingerprint:
                raise Refused("observation_identity_conflict")
            request = {"version": 1, "occurrence": occurrence, "work_ref": work_ref,
                       "trigger_ref": "mp-event:" + urllib.parse.quote(event["source"], safe="") + ":" + urllib.parse.quote(event["id"], safe="")}
            if not event_path.exists():
                save(event_path, event)
            request_path = directory / "request.json"
            if request_path.exists() and parse(read(request_path)) != request:
                raise Refused("retained_request_changed")
            save(request_path, request)
            if not pending:
                pending = {"occurrence": occurrence, "fingerprint": fingerprint, "next": page["next"], "handled": False}
                self.state["pending"] = pending
                self.persist()
            handled_path = directory / "handled.json"
            if handled_path.exists():
                receipt = self.retained_receipt(directory, request, fingerprint)
            else:
                result = self.dispatch("prepare", directory)
                if result.get("disposition") != "reported":
                    plan = result.get("plan_digest")
                    if result.get("disposition") not in ("prepared", "report_pending", "unresolved", "launch_intent") or not isinstance(plan, str) or not HEX.fullmatch(plan):
                        return {"version": 1, "disposition": "pending", "dispatch_disposition": result["disposition"], "acknowledged": False}, 4
                    result = self.dispatch("run", directory, plan)
                if result.get("disposition") != "reported" or result.get("ack_eligible") is not True:
                    return {"version": 1, "disposition": "pending", "dispatch_disposition": result["disposition"], "acknowledged": False}, 4
                receipt = self.handling_receipt(result, request, directory, fingerprint)
            pending["handled"] = True
            self.persist()
            self.source.ack(page["next"])
            self.state.update(pending=None, last_ack=page["next"])
            self.persist()
            return {"version": 1, "disposition": "acknowledged", "acknowledged": True,
                    "occurrence": occurrence, "evidence": receipt["evidence"], "next": page["next"]}, 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("once",))
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        config, policy, token = configuration(args.config)
        result, code = Consumer(config, policy, token).once()
    except Refused as exc:
        result, code = {"version": 1, "disposition": "refused", "reason": str(exc), "acknowledged": False}, 2
    except Retry as exc:
        result, code = {"version": 1, "disposition": "pending", "reason": str(exc), "acknowledged": False}, 4
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError):
        result, code = {"version": 1, "disposition": "refused", "reason": "invalid_or_unavailable_state", "acknowledged": False}, 2
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
