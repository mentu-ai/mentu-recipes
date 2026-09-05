# Mentu Recipes

[![CI](https://github.com/mentu-ai/mentu-recipes/actions/workflows/ci.yml/badge.svg)](https://github.com/mentu-ai/mentu-recipes/actions/workflows/ci.yml)
[![License: Source Available](https://img.shields.io/badge/license-source--available-blue.svg)](LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#requirements)
[![Swift 6.0](https://img.shields.io/badge/swift-6.0-orange.svg)](Package.swift)

### [Documentation](docs/README.md) | [Examples](examples/README.md) | [Recipe schema](docs/recipe-schema.md) | [CLI reference](docs/cli.md)

Mentu Recipes runs multi-step agent workflows defined as plain JSON files, where
each step declares up front where it may write and what must be true when it
finishes. The runner holds it to that: writes outside the declared boundary are
quarantined instead of committed, declared artifacts are committed when the step
closes, deterministic checks are recorded against the claim, and every run leaves
a reviewable record on disk.

Steps run against OpenAI, the Claude and Codex CLIs, DeepSeek,
OpenAI-compatible endpoints, local model servers, or a local shell. Recipes are
files, so they diff, review and version like the rest of your code.

## Install

```sh
curl -fsSL https://get.mentu.ai | sh
mentu-recipes setup
```

Apple Silicon and Intel, macOS 13 or later. The script checks the download
against the checksums published with the release and installs into
`~/.local/bin`, with no `sudo` and no shell profile edits. It is
[scripts/install.sh](scripts/install.sh) in this repository, so you can read it
first. Homebrew, the signed package and a source build are in
[docs/install.md](docs/install.md).

`setup` shows what is on this Mac, writes one example recipe where you are, runs
it with the shell backend, and prints the record. `mentu-recipes list` shows the
recipes a workspace can run.

### Using Claude Code?

```sh
claude plugin marketplace add mentu-ai/mentu-recipes
claude plugin install mentu-recipes@mentu
```

This repository is a Claude Code marketplace. The plugin carries two skills,
`writing-recipes` and `reading-run-records`, and two commands,
`/mentu-recipes:new` and `/mentu-recipes:run`. See
[plugins/mentu-recipes](plugins/mentu-recipes).

## Then choose your path

| I want to | Start here |
| --- | --- |
| **Run a recipe** and see the contract enforced | [Run a recipe](#run-a-recipe) |
| **Author a recipe** of my own | [Author a recipe](#author-a-recipe) |
| Read **worked examples** with real transcripts | [Examples](#examples) |
| Know **what this runner does and does not do** | [Scope](#scope) |

## Requirements

macOS 13 or later and a Swift 6.0 toolchain to build from source. The `shell`
backend needs nothing else; provider backends need their own credentials.

## Run a recipe

New here? The first-run wizard shows what is on this Mac, places an example
recipe in the workspace, runs it with the shell backend, and prints the record:

```sh
mentu-recipes setup
```


Install the CI-built binary with Homebrew:

```sh
brew install mentu-ai/tap/mentu-recipes-bin
```

Every release asset is built by GitHub Actions from the tagged source and
carries a build provenance attestation you can check yourself; the commands
and a real transcript are in [VERIFICATION.md](VERIFICATION.md).

Or build from source:

```sh
git clone https://github.com/mentu-ai/mentu-recipes.git
cd mentu-recipes
swift build
swift run mentu-recipes check shell-smoke
swift run mentu-recipes run shell-smoke
```

The bundled demos need no API key. Run one in a scratch workspace:

```sh
examples/run-demo.sh hello-justifiable
```

```
▶ produce · shell
PRODUCE_COMPLETE
▶ prove · shell
PROVE_COMPLETE

✓ hello-justifiable · 2 step(s) · ok
Run record: .../.mentu/runs/run_20260822024934_1F3BF42F/run.json

commits the runner made for declared artifacts:
8ea5fc2 chore: mentu-recipes step produce (run_20260822024934_1F3BF42F)
```

`produce` declared `examples/.work/hello.md` and wrote exactly that, so the
runner committed it. `prove` asserted the file says what `produce` claimed. Had
`produce` written anything it did not declare, that change would have been
written to a quarantine patch and left out of the commit.

Inspect what happened:

```sh
mentu-recipes report <run-id> --format markdown
mentu-recipes analyze-runs
```

## Author a recipe

```sh
mentu-recipes init          # creates .mentu/recipes and .mentu/prompts
```

A recipe is JSON. A step names a backend, a prompt or prompt file, and the
claims it is willing to be held to:

```json
{
  "name": "tidy-changelog",
  "type": "sequence",
  "steps": [
    {
      "label": "edit",
      "backend": "claude",
      "prompt_file": "PROMPT-tidy.md",
      "completion_keyword": "TIDY_COMPLETE",
      "expected_changes": ["CHANGELOG.md"],
      "timeout": 300
    },
    {
      "label": "prove",
      "backend": "shell",
      "depends_on": ["edit"],
      "prompt": "echo PROVE_COMPLETE",
      "completion_keyword": "PROVE_COMPLETE",
      "verify": {
        "grep_absent": [
          { "file": "CHANGELOG.md", "pattern": "TODO",
            "description": "the changelog must not ship with TODO markers" }
        ],
        "commands": ["git diff --stat --exit-code || true"]
      }
    }
  ]
}
```

Three fields carry the contract:

- **`expected_changes`** bounds the writes. Matching files are committed when the
  step closes; anything else is quarantined as a patch under the run directory.
- **`verify`** is the proof. `grep_present` and `grep_absent` assert file
  contents, `commands` runs shell assertions, `file_absent` asserts absence, and
  `git_clean_outside` bounds writes without committing.
- **`completion_keyword`** is the completion signal. The step is complete only if
  the keyword appears in its output.

Check the recipe before you run it:

```sh
mentu-recipes check tidy-changelog
mentu-recipes doctor tidy-changelog --strict
```

`doctor` scores a recipe out of 100 and names what is missing: steps that write
without declaring a boundary, non-shell steps with no observable completion
signal, unknown backends, unsupported per-backend options, and shell commands
that look destructive. `--strict` makes warnings fail, which is what you want in
CI.

Recipes resolve from `<workspace>/.mentu/recipes` then `~/.mentu/recipes`, by
name. Prompts resolve from the matching `prompts` directories. Paths outside
those roots, `~` expansion, traversal and symlink escapes are all rejected.

Full field reference: [docs/recipe-schema.md](docs/recipe-schema.md).
Verification semantics: [docs/verification.md](docs/verification.md).

## Scope

This repository is the local runner, and it is worth being exact about where it
ends so nothing here reads as a bigger claim than it is.

**It implements** the recipe and step model, DAG scheduling with derived layers,
declared write boundaries with quarantine of undeclared changes, deterministic
verification, per-backend completion policy, retries and timeouts, resume and
per-step retry, run records under `.mentu/runs/`, local run analytics, and
Keychain-backed credential resolution.

**It does not implement** an append-only hash-chained ledger, trust scoring,
hash-gated recipe commitment, or per-step worktree isolation. Those belong to the
full Mentu engine, which is not distributed here. Run records in this runner are
plain JSON written per run: they are not chained, and nothing in this runner
verifies them after the fact. Where that boundary changes how you should author a
recipe, the [examples](examples/README.md) say so at the point it matters.

## Examples

Three recipes with real transcripts, including the exact refusals you hit when
you leave the contract fields out:

- **[hello-justifiable](examples/hello-justifiable/README.md)**: two steps, one
  produces under a declared path and one proves the artifact. Shows the
  `missing_expected_changes` warning, a quarantined stray write, and a drifting
  claim caught by `grep_present`.
- **[demo-compound](examples/demo-compound/README.md)**: two child recipes run
  concurrently, a third joins them. Shows dependency validation refusals and why
  a missing `depends_on` produces a result that changes between runs.
- **[demo-parallel](examples/demo-parallel/README.md)**: a four-layer DAG closed
  by a sentinel step. Shows why concurrent steps must not declare
  `expected_changes` in a shared workspace, with the failing run record.

All three use the `shell` backend and need no credentials.

## Backends

| Backend | Execution | Notes |
| --- | --- | --- |
| `shell` | local command | Succeeds by exit code. Never selected automatically. |
| `openai` | OpenAI Responses API | `OPENAI_API_KEY` or vault key `openai-api-key`. |
| `claude` | local Claude CLI | Requires the CLI on `PATH`. |
| `codex` | local Codex CLI | Requires the CLI on `PATH`. |
| `deepseek` | OpenAI-compatible chat | `DEEPSEEK_API_KEY` or vault key `deepseek-api-key`. |
| `openai-compatible` | any compatible chat API | For local model servers and third-party hosts. |

```sh
mentu-recipes adapters                    # what is registered and available
mentu-recipes adapters --explain claude   # capabilities of one backend
```

Credentials come from recipe env, process env, or the macOS Keychain via
`mentu-recipes vault`. Built-in OpenAI and DeepSeek credential names are pinned
to their official hosts, so a custom `base_url` cannot quietly receive one.

## Security boundary

Treat recipes as code. A recipe can call external providers and, with a `shell`
step, run local commands. Review third-party recipes before running them.

Step working directories are confined to the selected workspace, prompt paths are
confined to the prompt roots, and provider credentials are not written to run
logs by the runner. Before publishing an artifact, run the release scanner:

```sh
swift run mentu-recipes scan .
```

Details in [docs/security-model.md](docs/security-model.md). To report a
vulnerability, see [SECURITY.md](SECURITY.md).

## Status

Honest state of this repository, verified on 2026-09-02 on macOS 15 with Swift 6:

- `swift build`: clean, no errors.
- `swift test`: **70 tests, 0 failures**, in about 2 seconds. No hangs, no
  crashes. The swift-testing half of the run is empty; every test here is XCTest.
- All six bundled demo recipes score **100 with no findings** under
  `mentu-recipes doctor`, and all three demos were executed end to end for the
  transcripts in [examples/](examples/README.md).

Known limitations, all documented rather than papered over:

- **Concurrent steps must not declare `expected_changes` in a shared workspace.**
  Steps in one layer share a git working tree and each commits when it closes, so
  simultaneous committers race and the loser is marked failed despite succeeding.
  Use `verify.git_clean_outside` on concurrent steps and let a serial step commit.
  Worked through, with the failing run record, in
  [examples/demo-parallel](examples/demo-parallel/README.md).
- **`grep_present` and `grep_absent` are bookkeeping, not gates.** An unmet
  assertion marks the step `warn_bookkeeping` and records the message, but the
  run continues. Put assertions that must stop a run in `verify.commands`.
- **A compound or parallel recipe must still carry a `steps` key**, even an empty
  one, or it fails to load with a decoding error that does not name the field.
- **Cloud mode is optional and off by default.** Local execution never depends on
  it, and step output is only sent when a recipe sets
  `"cloud": { "evaluate_steps": true }`.

This repository is the local runner. Mentu's hosted intelligence lives behind
`api.mentu.ai` and is not distributed here, and neither is the full Mentu engine.

## Contributing

Issues and pull requests are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) first. CI builds, tests, runs the release
source scan and the release gate on every pull request; run
`swift test && swift run mentu-recipes scan .` before you open one.

## License

Source-available under the Mentu Recipes Source Available License v1.0; see
[LICENSE](LICENSE).
