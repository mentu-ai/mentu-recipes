# Release Process

This repo ships a public source package and a signed macOS package.

## Source Gate

Run:

```sh
swift test
swift run mentu-recipes scan .
./scripts/release-validate.sh --source
```

The source gate checks for:

- protected internal terms
- likely secret tokens
- local user paths
- confidential markers
- protected local state paths

The source gate runs from the public repo as checked out. It does not depend on
a sibling private source tree.

## macOS Package Gate

The release script builds, strips, signs, validates, packages, notarizes, and
staples the package:

```sh
./scripts/release-macos.sh
```

Maintainers who intentionally want to refresh the public runtime from a sibling
source checkout can opt in:

```sh
SYNC_FROM_SOURCE=1 ./scripts/release-macos.sh
```

The sync step copies only `Package.swift`, `Sources`, and `Tests`; public docs,
license, examples, and release materials stay owned by this repository.

The package gate scans:

- compiled binary strings
- compiled binary symbols
- expanded package payload strings
- package payload shape

Scan staged, stripped artifacts. Raw SwiftPM release binaries can include local
build paths before `strip -x`, and the scanner will correctly reject them.

## Published Artifacts

For `v0.1.0`:

- package: `mentu-recipes-0.1.0-macos-arm64.pkg`
- SHA-256: `a6ab0e0125c90cb1d57361972dc9eeada229a7d9b4c8d3599388c1ada6cee560`
- Homebrew cask: `brew install --cask mentu-ai/tap/mentu-recipes`
- direct package:
  `https://github.com/mentu-ai/mentu-recipes/releases/download/v0.1.0/mentu-recipes-0.1.0-macos-arm64.pkg`

## Public Repo Rule

Only the recipe engine belongs here. Private platform internals and
confidential release materials must stay out of this repo.
