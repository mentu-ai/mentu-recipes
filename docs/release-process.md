# Release Process

This repository ships a public source package and CI-built, attested macOS
binaries. Nothing is built on a maintainer laptop. The full checklist a
maintainer follows is [RELEASE-CHECKLIST.md](../RELEASE-CHECKLIST.md); this
page explains the machinery it relies on.

## Source gate

Every pull request and every push to `main` runs:

```sh
swift test
swift run mentu-recipes scan .
./scripts/release-validate.sh --source
```

The source gate checks for protected internal terms, likely secret tokens,
local user paths, confidential markers, and protected local state paths. It
runs from this repository as checked out and does not depend on any sibling
private source tree.

## Release workflow

Pushing a tag of the form `vX.Y.Z` runs `.github/workflows/release.yml`, which:

1. refuses to continue unless `Sources/mentu-recipes/Version.swift` declares
   the same version as the tag;
2. runs the test suite and the source gate;
3. builds a universal release binary and splits it into `arm64` and `x86_64`
   artifacts, stripped and ad-hoc signed;
4. runs the binary gate (`release-validate.sh --binary`) on each artifact;
5. writes `checksums.txt`;
6. publishes a Sigstore build-provenance attestation for both binaries;
7. creates the GitHub release with generated notes and the three assets.

The binary you download can be tied back to this workflow, this repository,
and the tagged commit:

```sh
gh attestation verify mentu-recipes-macos-arm64 --repo mentu-ai/mentu-recipes
```

## Distribution channels

| Channel | What it serves | How it is updated |
| --- | --- | --- |
| GitHub release | `mentu-recipes-macos-arm64`, `mentu-recipes-macos-x86_64`, `checksums.txt` | by `release.yml` on tag push |
| Homebrew formula `mentu-ai/tap/mentu-recipes-bin` | the attested release binaries | a commit to the tap bumping `version` and both `sha256` values |
| Homebrew cask `mentu-ai/tap/mentu-recipes` and the `get.mentu.ai` installer | a signed and notarized `.pkg` registered in the Mentu release manifest | `scripts/release-macos.sh` produces the package; the manifest is updated through the release registry |

The formula is the recommended path. The package channels require the
notarized `.pkg`; a release that does not produce one must leave the cask and
the manifest untouched, so they never point at a version whose package does not
exist.

## Public repo rule

Only the recipe runner belongs here. Private platform internals and
confidential release materials stay out of this repository, and the source
gate enforces the terms that would reveal them.
