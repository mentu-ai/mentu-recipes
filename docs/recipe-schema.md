# Recipe Schema

A recipe is a JSON object with a name and a list of steps.

## Top-Level Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `type` | string | no | `sequence`, `formula`, `compound`, `pipeline`, or `parallel`. Default is `sequence`. |
| `name` | string | yes | Recipe name. |
| `description` | string | no | Human-readable description. |
| `backend` | string | no | Default backend for steps. |
| `model` | string | no | Default model for steps. |
| `env` | object | no | Recipe-level environment values. |
| `providers` | object | no | Custom provider definitions. |
| `cloud` | object | no | Optional cloud behavior. |
| `hooks` | object | no | Optional shell hooks around runs and steps. |
| `max_parallel` | integer | no | Max parallelism for wave or child-recipe execution. |
| `steps` | array | for `sequence` and `formula` | Ordered or dependency-linked steps. |
| `recipes` | array | for `compound`, `pipeline`, and `parallel` | Child recipe nodes. |

## Step Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `label` | string | yes | Unique step label. |
| `backend` | string | no | Step backend. Overrides recipe and CLI defaults. |
| `model` | string | no | Step model. Overrides recipe and CLI defaults. |
| `prompt` | string | no | Inline prompt or shell command. |
| `prompt_file` | string | no | Prompt file name from prompt roots. |
| `dir` | string | no | Relative step working directory inside workspace. |
| `env` | object | no | Step-level environment values. |
| `timeout` | integer | no | Timeout in seconds. Default is 1800. |
| `completion_keyword` | string | no | Required output text for local completion. Codex requires assistant output and a successful structured terminal event. |
| `depends_on` | array | no | Step labels that must run first. |
| `max_retries` | integer | no | Number of retries after the first attempt. |
| `retry_backoff_ms` | integer | no | Wait time between attempts. |
| `max_output_bytes` | integer | no | Output capture limit. Default is 5000000. |
| `reasoning` | string | no | Provider reasoning effort when supported. |
| `thinking` | string | no | Agent CLI thinking option when supported. Rejected by the Codex CLI adapter. |
| `max_output_tokens` | integer | no | Provider output token cap when supported. Rejected by the Codex CLI adapter. |
| `allowed_tools` | array | no | Agent CLI allow-list when supported. Rejected by the Codex CLI adapter, including an empty list. |
| `disallowed_tools` | array | no | Agent CLI deny-list when supported. Rejected by the Codex CLI adapter, including an empty list. |
| `sandbox` | string | no | Codex CLI only: `read-only`, `workspace-write` (default), or `danger-full-access`. |
| `expected_changes` | array | no | Repo-relative paths or globs the step is allowed to commit. |
| `verify` | object | no | Deterministic verification requirements. |

Each step must provide either `prompt` or `prompt_file`.

### Codex step validation

`sandbox` is a step field. Its value must be one of the three listed modes, and
the selected backend must be the Codex CLI adapter. Full access requires the
explicit value `danger-full-access`. The setting controls the Codex child
process; it does not prevent the runner from writing run artifacts or constrain
separate recipe hooks and verification commands.

Backend-specific validation follows the same selection order as execution:
step `backend`, CLI `--backend`, then recipe `backend`. When the backend is
auto-detected, the runner validates the selected adapter before starting the
step. `check` validates any backend declared in the recipe; `plan` and execution
also account for CLI overrides.

For Codex, non-null `allowed_tools`, `disallowed_tools`, `max_output_tokens`, and
`thinking` values are errors, rather than silently ignored settings. Use
`reasoning` for reasoning effort. See [Codex CLI](providers.md#codex-cli) for its
sandbox and completion rules.

## Recipe Node Fields

Child recipe nodes are used by `compound`, `pipeline`, and `parallel`.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `label` | string | no | Node label. Defaults to `recipe`. |
| `recipe` | string | yes | Recipe name or safe recipe path to run. |
| `depends_on` | array | no | Other node labels that must complete first. |
| `vars` | object | no | Variables passed to the child recipe. |

## Hook Fields

```json
{
  "hooks": {
    "before_run": ["echo starting"],
    "before_step": ["echo step $MENTU_RECIPES_STEP"],
    "after_step": ["echo done"],
    "on_error": ["echo failed"],
    "after_run": ["echo finished"]
  }
}
```

Hooks run through `/bin/sh` with `MENTU_RECIPES_*` context variables and are
recorded in `run.json`.

## Expected Changes

```json
{
  "expected_changes": [
    "Sources/",
    "Tests/**/*.swift",
    "README.md"
  ]
}
```

When a successful step declares `expected_changes` inside a git worktree, the
runner commits matching dirty paths and writes unrelated dirty changes into a
quarantine patch under the run directory. Absolute, home-rooted, and traversal
entries are ignored.

The runner compares each step against a pre-step workspace baseline. Dirty files
that existed before the step are recorded as pre-existing and are not blamed on
the step. If a step both commits expected files and creates unrelated files, the
unrelated files are quarantined and the step is recorded as
`warn_bookkeeping`.

## Cloud Fields

```json
{
  "cloud": {
    "enabled": true,
    "evaluate_steps": false
  }
}
```

`enabled` controls cloud run tracking. `evaluate_steps` controls whether step
output tails are sent for cloud evaluation.

## Provider Fields

```json
{
  "providers": {
    "my-provider": {
      "api": "chat_completions",
      "base_url": "https://example.com/v1",
      "api_key_env": "MY_PROVIDER_API_KEY",
      "api_key_vault": "my-provider-api-key",
      "model": "my-model"
    }
  }
}
```

Supported `api` values:

- `responses`
- `chat_completions`
- `cli`
- `shell`

## Minimal Example

```json
{
  "name": "shell-smoke",
  "steps": [
    {
      "label": "say-hello",
      "backend": "shell",
      "prompt": "echo MENTU_RECIPES_COMPLETE",
      "completion_keyword": "MENTU_RECIPES_COMPLETE"
    }
  ]
}
```
