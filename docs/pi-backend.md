# Pi agent and token usage

The opt-in Pi adapter runs the installed Pi coding agent, including its tools
and explicitly selected skills. It is not the `openai-chat` adapter under a
different name. It requires Pi 0.84.1 or newer and Pi's Node.js runtime, version
22.19 or newer. Mentu launches Pi directly through its existing process runner.
There is no embedded JavaScript gateway, request ledger, or inference budget.
Default backend selection and existing recipes are unchanged.

## Configuration

Use a named provider with `api: "cli"` and `agent: "pi"`, an explicit OpenAI-compatible Chat
Completions URL, an exact model identifier, and a provider-specific environment
or vault key. Inspect your server's model catalog first. Mentu does not discover
models or silently select a fallback provider.

```json
{
  "name": "pi-inspect",
  "providers": {
    "local-agent": {
      "api": "cli",
      "agent": "pi",
      "base_url": "http://127.0.0.1:8080/v1",
      "api_key_env": "LOCAL_AGENT_KEY",
      "model": "your-exact-model-id",
      "max_tokens_field": "max_tokens",
      "context_window": 32768,
      "skills": []
    }
  },
  "steps": [{
    "label": "inspect",
    "backend": "local-agent",
    "prompt": "Read README.md and describe the project. End with INSPECTED.",
    "allowed_tools": ["read"],
    "completion_keyword": "INSPECTED",
    "max_output_tokens": 2048,
    "timeout": 120,
    "max_retries": 0,
    "verify": {"git_clean_outside": []}
  }]
}
```

| Field | Behavior |
|-------|----------|
| `agent` | Which agent CLI an `api: "cli"` provider drives: `claude` (default), `codex`, or `pi`. |
| `base_url`, `model` | Explicit endpoint and exact model for this provider. |
| `api_key_env`, `api_key_vault` | Credential source; not a key embedded in the recipe. |
| `max_tokens_field` | `max_tokens` (default) or `max_completion_tokens`, selected through Pi's compatibility setting. |
| Step `max_output_tokens` | Pi model output limit per completion; defaults to 16384. It is not a total run budget or token measurement. |
| `context_window` | Pi model metadata, defaults to 32768; not proof of server capacity. |
| `skills` | Explicit paths loaded with `--skill`; other skills are not discovered. |

Allowed/denied tools use Pi names: `read`, `bash`, `edit`, `write`, `grep`,
`find`, `ls`. The default allow-list is `read,bash,edit,write`; an empty list
disables tools. Reasoning overrides are not supported; the profile requests
thinking off. Tool execution happens with the caller's normal permissions.

## Token accounting

Each adapter invocation sums the usage on Pi's authoritative assistant
`message_end` events, including intermediate tool-loop turns. It does not count
the repeated messages in `agent_end` again. Input includes Pi's `input`,
`cacheRead` and `cacheWrite` counters; output uses `output`. These populate the
existing step `input_tokens` and `output_tokens` in `run.json` and reports.

These are **Pi-reported tokens**, not independent HTTP receipts or a billing
audit. Byte counts are not token counts, and no byte estimate is used here.
Missing or invalid Pi usage remains unknown. Pi initializes absent provider
usage to zeros, so an all-zero assistant usage object is also treated as
unknown rather than claimed as measured zero consumption. If any assistant
turn has unknown usage, totals for that invocation remain unknown.

The existing run record describes the recorded step execution. It is not a
lifetime cost ledger: a later retry replaces the step result, and child runs
have their own records. Do not label a sum of current step results as all-time
spending across retries or count parent and child records twice. Capture
per-attempt records externally when an experiment requires cumulative usage.
The adapter does not impose cross-step request, concurrency or token budgets.

## Isolation and completion

Every launch receives a temporary private profile. It disables automatic Pi
and SDK retries, compaction, extension/context discovery, update checks, and
global provider configuration. Explicit Mentu step retries remain available.
The profile is removed on normal return, including ordinary execution errors.
An abrupt process kill may leave a temporary directory containing the prompt,
but the profile contains only a credential reference, not the provider key.

The selected credential is passed through a dedicated environment variable,
not command-line arguments or JSON files. Pi and its tools can access that
credential. This is **not an OS sandbox**: authorized tools, skills and hooks
retain normal filesystem and network access. Use an external sandbox for
untrusted work. Skills, executable versions, and tool-readable files are not
snapshotted by this adapter; clients promising immutable execution must pin
those inputs separately.

A final successful Pi assistant completion and a zero process exit are both
required. An error, abort, or length limit cannot pass merely because Pi exits
zero or prints the completion keyword. Timeouts use Mentu's existing process
runner. These execution records are not formal Mentu Commitment Protocol data.

## Validation

Parser tests cover multi-turn totals, cache accounting, duplicated end events,
missing/invalid usage, truncated completion and failure states. Real installed
Pi fixture tests exercise read/write tools, an explicit skill, token-field
mapping, unknown usage, cache counts, provider failures and persisted run
records against a deterministic loopback HTTP provider. They make no model
inference calls and do not measure model quality.

The real-CLI suite skips when Pi or Node is absent. For a mandatory integration
job, provision Node 22.19 or newer, install
`npm install --global @earendil-works/pi-coding-agent@0.84.1`, and run
`swift test --filter 'PiCLIFixtureTests|PiJSONParserTests'`. The existing CI
workflow is unchanged; a job that skips Pi is not real-CLI acceptance evidence.
The maintainer's pinned Pi CI job remains a prerequisite for merging this
backend. Node belongs to Pi's installed toolchain, not an additional Mentu
runtime component.
