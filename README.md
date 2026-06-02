# Mentu Recipes

Mentu Recipes is a source-available runner for file-based agent workflows.
Define recipes in `.mentu/recipes`, keep reusable prompts in `.mentu/prompts`,
and run them locally against OpenAI, Claude, OpenAI-compatible providers,
local model servers, or shell steps.

The local runner is an execution kernel: it handles recipe discovery, prompt
rendering, provider-neutral execution, retries, timeouts, vault/env resolution,
run logs, deterministic verification, hooks, DAG/parallel execution, and
expected-change commit quarantine.

Mentu Intelligence lives behind `api.mentu.ai`. When configured, it can add
cloud verdicts, trust scoring, completion checks, correction learning, feature
gates, and future premium recipe intelligence. Local execution still works
without a Mentu API key.

This repository contains the public runner layer only. It does not contain
Mentu private platform internals, proprietary evaluation logic, private model
runtime code, confidential release systems, or internal automation assets.

## Quick Start

Install the signed macOS package with Homebrew:

```sh
brew install --cask mentu-ai/tap/mentu-recipes
```

Or install the published package directly from GitHub:

```sh
VERSION=0.1.0
PKG="mentu-recipes-${VERSION}-macos-arm64.pkg"
BASE="https://github.com/mentu-ai/mentu-recipes/releases/download/v${VERSION}"
curl -fL "$BASE/$PKG" -o "$PKG"
echo "a6ab0e0125c90cb1d57361972dc9eeada229a7d9b4c8d3599388c1ada6cee560  $PKG" | shasum -a 256 -c -
spctl -a -vv -t install "$PKG"
sudo installer -pkg "$PKG" -target /
```

Or build from source:

```sh
swift build
swift run mentu-recipes check shell-smoke
swift run mentu-recipes run shell-smoke
```

## Documentation

The public documentation is in [docs/README.md](docs/README.md).

Start with:

- [Overview](docs/overview.md)
- [Install](docs/install.md)
- [Quick Start](docs/quick-start.md)
- [Recipe Schema](docs/recipe-schema.md)
- [Providers](docs/providers.md)
- [Runtime Intelligence](docs/runtime-intelligence.md)
- [Security Model](docs/security-model.md)
- [Runtime Intelligence Build](docs/BUILD-Mentu-Recipes-Intelligence-v1.md)

Recipe files are discovered in this order:

1. `<workspace>/.mentu/recipes`
2. `~/.mentu/recipes`
3. direct file path, only when the file is still inside one of those roots

Prompt files are discovered in:

1. `<workspace>/.mentu/prompts`
2. `~/.mentu/prompts`

Prompt paths are always resolved inside those prompt roots. Absolute paths,
`~`, path traversal, and symlink escapes are rejected.

## What A Recipe Does

A recipe is a JSON file with a name, optional defaults, and one or more steps.
Each step chooses a backend, prompt source, timeout, retry behavior, and an
optional deterministic completion keyword. Steps run locally and write run
records under `.mentu/runs/<run-id>/`.

Recipes are plain files. You can keep them in a project, review them in code
review, and run them from CI or a local terminal.

## Example Recipe

```json
{
  "name": "shell-smoke",
  "description": "One local shell step.",
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

## Commands

```sh
mentu-recipes init
mentu-recipes check <recipe-or-path>
mentu-recipes run <recipe-or-path> [--workspace PATH] [--backend NAME] [--model MODEL] [--cloud] [--max-parallel N] [--var KEY=VALUE]
mentu-recipes resume <run-id>
mentu-recipes retry-step <run-id> <step-label>
mentu-recipes report <run-id> [--format markdown|json|csv]
mentu-recipes doctor <recipe-or-path> [--strict]
mentu-recipes analyze-runs [--format markdown|json|csv]
mentu-recipes adapters [--json|--explain NAME]
printf '%s' "$SECRET" | mentu-recipes vault set <key>
mentu-recipes vault get <key>
mentu-recipes vault list
mentu-recipes scan [path] [--artifact PATH]
```

## Built-In Backends

- `shell`: runs an explicit local shell command and succeeds by exit code.
- `openai`: uses the OpenAI Responses API for ChatGPT and GPT models.
- `claude`: uses the local Claude CLI when installed.
- `codex`: uses the local Codex CLI when installed.
- `deepseek`: uses DeepSeek through an OpenAI-compatible chat API.
- `openai-compatible`: can target providers with compatible chat APIs.

Shell is explicit only. It is never selected automatically.

## Provider Credentials

Credentials are resolved from explicit recipe env, process env, and the
macOS Keychain service used by Mentu vault keys.

Common key names:

- `OPENAI_API_KEY` or vault key `openai-api-key`
- `ANTHROPIC_API_KEY` or vault key `anthropic-api-key`
- `DEEPSEEK_API_KEY` or vault key `deepseek-api-key`
- `MENTU_API_KEY` or vault key `mentu-api-key`

Custom provider `base_url` values are a trust boundary: a recipe can direct
prompts and provider-specific API keys to that host. Built-in OpenAI and
DeepSeek credential names are pinned to their official API hosts; use a
provider-specific env or vault key for third-party providers.

Shell steps are explicit only and run the command you put in the recipe. Treat
recipes with shell steps like code. Step `dir` values are confined to the
workspace; choose the workspace root intentionally with `--workspace`.

## Cloud Mode

Cloud mode is local-only by default. Enable run tracking explicitly with:

```sh
mentu-recipes run my-recipe --cloud
```

A recipe can also opt in with `"cloud": { "enabled": true }`. Cloud failures do
not stop local execution. Runs are marked local-only when Mentu Intelligence is
unavailable. Step output is not sent for cloud evaluation unless a recipe
explicitly sets `"cloud": { "evaluate_steps": true }`.

## Security Boundary

Treat recipes as code. A recipe can call external model providers and, when a
step uses the `shell` backend, execute local commands. Review third-party
recipes before running them.

The runner rejects prompt paths outside configured prompt roots and rejects step
working directories outside the selected workspace. Provider credentials are
read from environment variables or vault keys and are not written to run logs by
the runner. Built-in provider credentials are pinned to their official hosts so
a custom `base_url` cannot silently receive an OpenAI or DeepSeek key.

The public repository is intentionally limited to the local recipe runner. Mentu
private intelligence remains in the cloud API and is not distributed in this
source package.

## Release Check

Before publishing a source or binary artifact:

```sh
swift run mentu-recipes scan .
```

The scanner fails on private paths, likely secrets, confidential markers, and
protected Mentu platform terms that should not be present in the public repo.

For macOS package releases, the ship scripts also scan the stripped staging
binary and expanded package payload before notarization. Raw SwiftPM release
binaries can contain local build paths before stripping and should not be
published directly.

## License

Mentu Recipes is source-available under the included license. You may read, run,
copy, and modify it for personal, internal, educational, and evaluation use.
Commercial redistribution, hosted-service use, and competing commercial workflow
services require a separate written license from Mentu.
