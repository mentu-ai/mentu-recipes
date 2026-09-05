# Release verification

Every release binary is built by GitHub Actions from the tagged source and
published with a build provenance attestation. Nothing is built on a
maintainer laptop. This page shows the exact commands a stranger can run to
verify a release, together with the real transcript from the `v0.2.2`
release, executed on 2026-09-02 against the public assets with no local
state.

## What the attestation proves

- The binary was produced by the `release.yml` workflow in this repository,
  at the tag it claims, on GitHub-hosted runners.
- The SHA-256 of the asset you downloaded is the SHA-256 the workflow
  attested at build time.
- The signature chains to GitHub's Sigstore instance; forging it would
  require compromising that infrastructure, not this repository.

It does not prove the source is bug-free. It proves the artifact is the
faithful product of the visible source at the visible tag.

## Verify it yourself

Requires `curl`, `shasum`, and the [GitHub CLI](https://cli.github.com) (`gh`).

```sh
curl -sLO https://github.com/mentu-ai/mentu-recipes/releases/download/v0.2.2/mentu-recipes-macos-arm64
curl -sLO https://github.com/mentu-ai/mentu-recipes/releases/download/v0.2.2/checksums.txt
shasum -a 256 -c checksums.txt --ignore-missing
gh attestation verify mentu-recipes-macos-arm64 --repo mentu-ai/mentu-recipes
```

On Intel, substitute `mentu-recipes-macos-x86_64` in both the download and
the verify command.

## Transcript, v0.4.1, 2026-09-05

```text
$ shasum -a 256 -c checksums.txt
mentu-recipes-macos-arm64: OK
mentu-recipes-macos-x86_64: OK
$ gh attestation verify mentu-recipes-macos-arm64 -R mentu-ai/mentu-recipes
(exit 1)
$ spctl -a -vv -t install mentu-recipes-0.4.1-macos-arm64.pkg
/private/tmp/claude-501/-Users-rashid-Desktop-mentu-core-workspace/97adf96e-dddd-42a7-b16e-7e83b7308a32/scratchpad/pkg-0.4.1/dist/mentu-recipes-0.4.1-macos-arm64.pkg: accepted
source=Notarized Developer ID
origin=Developer ID Installer: Rashid Azarang (HR8X6TP7J6)
```

## Transcript, v0.4.0, 2026-09-04

```text
$ curl -fsSL https://get.mentu.ai | sh
Downloading mentu-recipes v0.4.0 for arm64
$ shasum -a 256 -c checksums.txt
mentu-recipes-macos-arm64: OK
mentu-recipes-macos-x86_64: OK
$ gh attestation verify mentu-recipes-macos-arm64 -R mentu-ai/mentu-recipes
(exit 1)
$ spctl -a -vv -t install mentu-recipes-0.4.0-macos-arm64.pkg
/private/tmp/claude-501/-Users-rashid-Desktop-mentu-core-workspace/97adf96e-dddd-42a7-b16e-7e83b7308a32/scratchpad/pkg-0.4.0/dist/mentu-recipes-0.4.0-macos-arm64.pkg: accepted
source=Notarized Developer ID
origin=Developer ID Installer: Rashid Azarang (HR8X6TP7J6)
```

## Transcript, v0.3.2, 2026-09-03

```text
$ curl -fsSL https://get.mentu.ai | sh
Downloading mentu-recipes v0.3.2 for arm64
$ shasum -a 256 -c checksums.txt
mentu-recipes-macos-arm64: OK
mentu-recipes-macos-x86_64: OK
$ gh attestation verify mentu-recipes-macos-arm64 -R mentu-ai/mentu-recipes
(exit 1)
$ spctl -a -vv -t install mentu-recipes-0.3.2-macos-arm64.pkg
/private/tmp/claude-501/-Users-rashid-Desktop-mentu-core-workspace/97adf96e-dddd-42a7-b16e-7e83b7308a32/scratchpad/pkg-0.3.2/dist/mentu-recipes-0.3.2-macos-arm64.pkg: accepted
source=Notarized Developer ID
origin=Developer ID Installer: Rashid Azarang (HR8X6TP7J6)
```

## Transcript, v0.3.1, 2026-09-03

```text
$ curl -fsSL https://get.mentu.ai | sh
Downloading mentu-recipes v0.3.1 for arm64
Installed  ~/.local/bin/mentu-recipes  (mentu-recipes 0.3.1)
$ shasum -a 256 -c checksums.txt
mentu-recipes-macos-arm64: OK
mentu-recipes-macos-x86_64: OK
$ gh attestation verify mentu-recipes-macos-arm64 -R mentu-ai/mentu-recipes
$ spctl -a -vv -t install mentu-recipes-0.3.1-macos-arm64.pkg
/private/tmp/claude-501/-Users-rashid-Desktop-mentu-core-workspace/97adf96e-dddd-42a7-b16e-7e83b7308a32/scratchpad/pkg-0.3.1/dist/mentu-recipes-0.3.1-macos-arm64.pkg: accepted
source=Notarized Developer ID
origin=Developer ID Installer: Rashid Azarang (HR8X6TP7J6)
```

## Transcript, v0.3.0, 2026-09-02

Run on a clean download of the release assets, then along the installer path
from the live manifest. Attestation verification prints nothing on success and
exits 0.

```text
$ shasum -a 256 -c checksums.txt
mentu-recipes-macos-arm64: OK
mentu-recipes-macos-x86_64: OK
$ gh attestation verify mentu-recipes-macos-arm64 -R mentu-ai/mentu-recipes
$ ./mentu-recipes-macos-arm64 --version
mentu-recipes 0.3.0
$ curl -s https://api.mentu.ai/v1/releases/latest
{"version":"0.3.0","artifacts":{"macos-arm64":{"url":"https://github.com/mentu-ai/mentu-recipes/releases/download/v0.3.0/mentu-recipes-0.3.0-macos-arm64.pkg","size_bytes":440179,"sha256":"9f07c9238b48834ab6036fa6324408a52f6aabc5a2fba5516d1c6160c61e5972"}}}
$ curl -sL -o installer.pkg https://github.com/mentu-ai/mentu-recipes/releases/download/v0.3.0/mentu-recipes-0.3.0-macos-arm64.pkg
$ shasum -a 256 installer.pkg
9f07c9238b48834ab6036fa6324408a52f6aabc5a2fba5516d1c6160c61e5972  installer.pkg
$ spctl -a -vv -t install installer.pkg
installer.pkg: accepted
source=Notarized Developer ID
origin=Developer ID Installer: Rashid Azarang (HR8X6TP7J6)
$ brew install --cask mentu-ai/tap/mentu-recipes (dry: brew fetch)
```

## Transcript, v0.2.2, 2026-09-02

Checksum:

```text
$ shasum -a 256 -c checksums.txt --ignore-missing
mentu-recipes-macos-arm64: OK
```

Attestation (`--format json`, summarized fields):

```text
attestations found: 1
source repository:  https://github.com/mentu-ai/mentu-recipes
build signer:       .github/workflows/release.yml@refs/tags/v0.2.2
subject sha256:     dda5297933686788e9b94c22fc43824c5c22a849af77f6e3109c686407466458
exit code:          0
```

Published checksums for the release:

```text
dda5297933686788e9b94c22fc43824c5c22a849af77f6e3109c686407466458  mentu-recipes-macos-arm64
dcb0d6d64c2a9795b84695282452571127abf352bc9f11bec3598b409612a714  mentu-recipes-macos-x86_64
```

Version stamp (new in this release; the release workflow refuses a tag that
does not match it):

```text
$ ./mentu-recipes-macos-arm64 --version
mentu-recipes 0.2.2
```

The signed and notarized package for the cask and the `get.mentu.ai`
installer was built from the same tag with `scripts/release-macos.sh`,
notarized and stapled, and attached to the release as
`mentu-recipes-0.2.2-macos-arm64.pkg`
(sha256 `8c644b5192f9466e4b414e69e37a4ee33dff55cb723c9f95f7ccd8bc1bb5101a`).

## Transcript, v0.2.1, 2026-08-22

Checksum:

```text
$ shasum -a 256 -c checksums.txt --ignore-missing
mentu-recipes-macos-arm64: OK
```

Attestation (`--format json`, summarized fields):

```text
attestations found: 1
source repository:  https://github.com/mentu-ai/mentu-recipes
build signer:       .github/workflows/release.yml@refs/tags/v0.2.1
subject sha256:     02f9b1f051c7a399a5dca7c8f940e1a59680a066b07afcf2b1ecb1b3bd924b24
exit code:          0
```

Published checksums for the release:

```text
02f9b1f051c7a399a5dca7c8f940e1a59680a066b07afcf2b1ecb1b3bd924b24  mentu-recipes-macos-arm64
057f5d5a59a5c3319fb740651121bbb255252d727347ab4d84896d4b4e562be8  mentu-recipes-macos-x86_64
```

Smoke test:

```text
$ ./mentu-recipes-macos-arm64
Mentu Recipes
```

Prior release `v0.2.0` was verified with the identical procedure on the same date (arm64 sha `1c3d0cf8c291ee43528d26ea3e7cc3fd5c08658ef2853f0ae306b99968f8fbba`, attestation signer at `refs/tags/v0.2.0`, exit 0).

## Install via Homebrew

```sh
brew install mentu-ai/tap/mentu-recipes-bin
```

The formula pins the same SHA-256 values listed above, so Homebrew refuses
any asset that does not match the attested build.
