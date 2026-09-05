# Mentu Recipes Documentation

Mentu Recipes is the public recipe engine: a local runner for file-based agent
workflows. These docs cover the runner, recipe files, prompts, providers,
credentials, shell steps, cloud hooks, local logs, deterministic checks, and
release validation.

Mentu private intelligence and internal platform systems are not documented in
this public repo.

## Start Here

- [Overview](overview.md)
- [Install](install.md)
- [Quick Start](quick-start.md)
- [Recipe Concepts](concepts.md)

## Authoring Recipes

- [Recipe Schema](recipe-schema.md)
- [Prompts And Variables](prompts-and-variables.md)
- [Providers](providers.md)
- [Pi Agent And Token Usage](pi-backend.md)
- [Credentials And Vault](credentials-and-vault.md)
- [Shell Steps](shell-steps.md)
- [Deterministic Verification](verification.md)

## Operations

- [CLI Reference](cli.md)
- [Admitted Execution](admitted-execution.md)
- [Cloud Hooks](cloud-hooks.md)
- [Run Records](run-records.md)
- [Runtime Intelligence](runtime-intelligence.md)
- [Security Model](security-model.md)
- [Release Process](release-process.md)

## Build Plans

- [Runtime Intelligence Build](BUILD-Mentu-Recipes-Intelligence-v1.md)

## Examples

- [Runnable examples](../examples/README.md): three demo recipes with real
  transcripts, including the refusals you hit when contract fields are missing.
- [Recipe snippets](examples.md)

## Scope

The main [README](../README.md#scope) states exactly what this runner implements
and what belongs to the full Mentu engine, which is not distributed here.
