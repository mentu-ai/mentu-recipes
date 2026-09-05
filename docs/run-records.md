# Run Records

Every run writes files under:

```text
.mentu/runs/<run-id>/
```

## `run.json`

The run record includes:

- run ID
- recipe name
- start and end time
- outcome
- cloud mode
- optional cloud run ID
- step records
- run-level hook records
- optional recipe reference
- optional pointers to `events.jsonl`, `state.json`, and `baseline.json`

## Step Output Files

Each step writes:

- `<label>.stdout`
- `<label>.stderr`

The step record points to those file names.

Steps may also include:

- `outcome`: `success`, `warn_bookkeeping`, `failed`, `skipped`, or `cancelled`
- `completion_method`
- token counts reported by a provider
- deterministic verification warnings and errors
- workspace drift attribution
- hook records
- a `git` record with committed paths, commit hash, and quarantined patch files

## `events.jsonl`

New runs also write an append-only event log. It records run start/end, resume,
step queue/start/retry/end, backend selection, verification, hooks, workspace
drift, quarantine, and sanitized errors. Each line is one JSON event. Readers
tolerate a malformed trailing line so interrupted runs remain inspectable.

## `state.json`

The state file powers resume and retry. It stores the original recipe reference,
run variables, backend/model overrides, and each step's current state. Completed
steps marked `success` or `warn_bookkeeping` are skipped during resume.

## `baseline.json`

The baseline file records workspace metadata captured before the run. Step-level
baselines are used internally to subtract pre-existing dirty files from
post-step drift checks.

## Cancelling an execution

For `run`, `resume`, and `retry-step`, the CLI handles `SIGINT` and `SIGTERM`
by cancelling the active execution task. Subprocess adapters forward `SIGTERM`
to their owned step process group (or the child PID when it has no independent
group), allowing a harness to shut down its own tools. A child that remains
running after two seconds is sent `SIGKILL`. Importing the core library does
not install signal handlers; callers cancel their Swift task instead.

The interrupted subprocess result has exit code `130` and cannot satisfy
completion, even if its signal handler exits zero or prints the completion
keyword. The CLI itself exits `130` for `SIGINT` or `143` for `SIGTERM`.
Partial attempt output is retained, and the interrupted run finishes as
`failed`. Cancellation does not launch automatic retries, subsequent steps,
verification commands, or hooks. Resume remains an explicit operation, with
the existing admission requirements when applicable; it preserves earlier
attempt files.

This is cooperative cancellation, not an OS containment boundary. A harness
must stop tools that it detached into other process groups. `SIGKILL` of the
CLI, machine failure, and arbitrary independently detached daemons do not
provide the same cleanup or final-record guarantee.

## Example Shape

```json
{
  "run_id": "run_20260517220000_abcd1234",
  "recipe_name": "shell-smoke",
  "outcome": "ok",
  "cloud_mode": "local-only",
  "steps": [
    {
      "label": "say-hello",
      "backend": "shell",
      "outcome": "success",
      "exit_code": 0,
      "completion_method": "keyword_output",
      "local_complete": true,
      "attempts": 1,
      "output_file": "say-hello.stdout",
      "error_file": "say-hello.stderr"
    }
  ]
}
```

Run records are local project state and are ignored by the public repo.
