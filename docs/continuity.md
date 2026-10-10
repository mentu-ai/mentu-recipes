# Continuity through bounded recipes

A routine can outlive any one agent conversation. A terminal command, ticket
event, scheduled action, or Monitor Protocol observation can invoke a predefined
recipe, publish its outcome, and exit. The next occurrence starts fresh work
using durable references and retained context.

This repository supplies two optional POSIX Python 3.10+ boundary adapters in
[`integrations/continuity`](../integrations/continuity). They use the existing
[admitted runner](admitted-execution.md); they do not implement another recipe
engine. Build the runner with Swift on its supported macOS platform.

## Two execution modes

| Mode | Lifetime | Required evidence |
| --- | --- | --- |
| Bounded routine | A new process for one authorized occurrence, then exit | Admission, provider completion, run record, external outcome receipt |
| Attend a live session | An existing human-opened frontend receives an observation | Live ownership binding, delivery, a new attended turn, disposition |

These adapters implement bounded routines. They do not add a native monitor to
stock Codex, resume a live conversation, acquire another frontend's writer lock,
or prove that an idle peer woke. An attended-session adapter belongs at the
harness boundary. Both modes can consume the same protocol through independent
subscriptions.

Codex `turn/steer` requires an active turn. `turn/start` can start a turn on an
existing thread; creating a thread is a separate operation. See the official
[App Server documentation](https://learn.chatgpt.com/docs/app-server).

### What a Codex launcher creates

1. Choose the workspace, saved CLI authentication, model and sandbox.
2. Invoke `codex exec --json` for a fresh bounded job, or start a foreground
   `codex -C /workspace` for interactive terminal work.
3. For structured integration, initialize an App Server connection, call
   `thread/start`, retain its ID, then call `turn/start` with the authorized task.
4. Retain the event stream and terminal outcome. `thread.started` alone proves
   neither successful work nor a new thread: resume also emits that event.
   Record the invocation mode and thread ID together.
5. For later continuity, resume a known thread through a frontend that can own
   it, or launch a fresh occurrence with selected retained context. Never use
   a fresh occurrence as an automatic retry for uncertain work.

CLI sessions persist by default; `--ephemeral` disables session persistence.
See [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode).
A persisted thread is distinct from an open desktop window. `codex app` opens
the desktop application for a workspace; that command alone does not establish
a new conversation or an app-to-terminal handoff.

A message saying a conversation is open in another app indicates existing
writer ownership. The owning frontend must release it before another resumes
that thread. The launcher should expose `busy` with an owner reason, not steal
the lock or silently fork a different conversation.

Tools belong to the hosting harness and its configuration. A terminal process
does not automatically inherit desktop browser control, connectors, dynamic
tools or application UI. A launcher must check the actual destination's
capabilities and authorization before selecting it. Keep thread identity,
frontend ownership, tool capabilities and work identity as separate fields.

## Responsibilities

```mermaid
flowchart LR
  A[Ticket, timer or monitor] --> B[Approved occurrence]
  B --> C[Retain pinned input bytes]
  C --> D[Review and admit exact recipe plan]
  D --> E[Bounded provider execution]
  E --> F[Durable outcome in work system]
  F --> G[Consumer acknowledges observation]
```

- **Trigger:** identifies an occurrence and existing work. It cannot choose a
  command, prompt, URL, credential, provider, or permission setting.
- **Operator policy:** fixes those choices and binds the runner and recipe by
  SHA256. New policy content needs a new occurrence or explicit reconciliation.
- **Resolver:** retains approved local files or exact HTTPS resources. Every
  resource has a digest, byte limit, deadline and declared use. Redirects fail.
- **Runner:** preserves sequence, formula and dependency semantics, enforces
  admission and workspace coordination, and records execution.
- **Reporter:** writes a result to the ticket or work system and returns its
  durable reference. It must be idempotent by `request_key`.
- **Consumer:** acknowledges only after a durable reported receipt.

Process completion, work acceptance, protocol acknowledgement and evidential
support are separate facts. A successful run does not close its ticket or prove
a claim. An epistemic work tree can cite the run record and input manifest;
an evolutionary graph can cite subsequent independent evaluation. Recipe
dependency edges must not become support edges automatically.

## Direct terminal use

Provision a private directory (`0700`) containing a policy (`0600`). See the
[example recipe and policy](../examples/continuity/README.md). Keep credentials
outside recipe prompts and version control.

```sh
python3 integrations/continuity/dispatch.py prepare \
  --policy /private/routine/policy.json --request /private/routine/request.json

# Review the retained manifest and plan, then use the returned digest.
python3 integrations/continuity/dispatch.py run \
  --policy /private/routine/policy.json --request /private/routine/request.json \
  --plan-digest REVIEWED_64_HEX_DIGEST

python3 integrations/continuity/dispatch.py status \
  --policy /private/routine/policy.json --request /private/routine/request.json
```

The request has exactly four fields:

```json
{
  "version": 1,
  "occurrence": "daily-review:2030-01-01",
  "work_ref": "ticket:review-123",
  "trigger_ref": "timer:daily-review/2030-01-01"
}
```

An action or another agent can execute the same commands under an operator's
existing authorization. The service exposing them must fix the policy path and
authenticate its caller. Passing an arbitrary policy is equivalent to allowing
arbitrary local commands; this CLI is not a remote authorization service.

The recipe reads `$CONTINUITY_MANIFEST` and its admission-bound
`$CONTINUITY_MANIFEST_SHA256`. Snapshot paths, bytes and provenance remain
available after the source changes or disappears. An HTTPS resource may be a
prompt only when the fixed policy marks it `authorized_prompt` and the fixed
recipe explicitly delegates to it. Other input is untrusted context.

An optional `auth_env` supplies a Bearer token to one exact HTTPS resource.
That name cannot appear in `inherit_env`. Resolver credentials therefore do
not enter the runner or reporter environment. Avoid signed URLs: source URLs
are retained in the private manifest.

Version 1 requires every step and child recipe in the resolved plan to match
the policy's explicit backend and model. Mixed-provider recipes require a
future explicit capability policy. Codex tool allow/deny fields and output-token
limits are rejected because this adapter cannot enforce them. Use an explicit
Codex sandbox; unattended read-only jobs should declare `"sandbox":"read-only"`.

## Monitor Protocol consumer

`monitor.py once --config /private/routine/monitor.json` pulls at most one event
from a pre-existing dedicated subscription. Provision the subscription through
your [Monitor Protocol service](https://github.com/mentu-ai/monitor-protocol).
Do not share it with another consumer.

The private configuration binds the service, subscription, token file, policy
digest, expected source, event type and work reference. It requires explicit
`standing_authorization: true`: the operator authorizes automatic admission of
plans resolved from that pinned policy. This does not claim that a human reviewed
every occurrence's generated plan.

Run `once` from a scheduler or an existing service supervisor. The command exits
when there is no event. Nothing installs a daemon, changes a shell profile,
starts a conversation, or enables repeated execution automatically.

Events are deduplicated by source and ID. Immutable content changes for the
same identity are refused. An exclusive local lock prevents two processes from
consuming the subscription concurrently. A cursor below retention fails rather
than resetting to the head. A failed acknowledgement can be retried from the
durable receipt without executing the recipe again.

## State and recovery

| State | Meaning | Safe next step |
| --- | --- | --- |
| `prepared` | Inputs and exact plan retained | Admit that digest |
| `launch_intent` | Durable intent written before spawning | Reconcile existing artifacts; never blindly relaunch |
| `unresolved` | Completion cannot be established | Investigate; no acknowledgement or automatic rerun |
| `report_pending` | Terminal result exists; reporter receipt missing | Retry only the idempotent reporter |
| `reported` | Result and external receipt durable | Consumer may acknowledge according to its policy |
| `busy` / `refused` | Ownership or binding did not permit progress | Resolve the specific conflict |

Dispatch exits: `0` prepared/status/reported success, `2` refused, `3` busy,
`4` unresolved, `5` report pending, `10` reported failure. Read JSON disposition
as well as the exit code. A failed job can be durably reported without claiming
success. A reporter must return exactly `{"evidence":"source-qualified-ref"}`
after storing the supplied result. Printing it first is insufficient.

Timeouts terminate the owned process group where possible and preserve an
unresolved outcome. Detached descendants or completed external effects cannot
be proven absent. One occurrence never automatically becomes a second model
attempt after uncertainty. This is not universal exactly-once execution.

## Operational limits and health

Track producer health, last pull, pending event, retained plan, active worker,
terminal result, reporter receipt and acknowledged cursor separately. A running
terminal or active subscription alone does not establish continuity. If the
producer stops publishing, a perfectly healthy worker receives no event.

The local journal assumes one POSIX host and a private filesystem. Same-UID
processes, a compromised reporter, changed provider binaries on PATH, provider
configuration, and arbitrary authorized hooks remain outside its isolation
boundary. Recipe sandbox controls the Codex child, not the whole host. Runner
pinning does not pin the entire installed toolchain.

The consumer intentionally handles one JSON observation at a time for one
approved work reference. It does not compact history, reset cursors, assign new
tickets, migrate subscriptions or recover expired leases. Provision broader
routing through explicit policies and a work service instead of allowing event
payloads to become executable instructions.

## Verification

```sh
swift test
swift run mentu-recipes scan .
python3 -B -m unittest discover -s integrations/continuity -p 'test_*.py'
```

The automated fixtures require no provider credentials. They test admission,
duplicate delivery, lost reporting, crash recovery, changed inputs, redirects
and refusal before acknowledgement. A real-provider trial must additionally
retain its binary versions, plan, input snapshots, provider result and external
receipt. Keep generated evidence and credentials outside this public repository.
