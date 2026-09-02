# Release checklist

One list, in order. Each step consumes the previous step's artifact.

## Before tagging

- [ ] `main` is green in CI and carries everything that ships.
- [ ] `Sources/mentu-recipes/Version.swift` declares the new version.
- [ ] `README.md` Status section reflects a fresh `swift test` run and any new limitation.
- [ ] `docs/` pages that name a version (`install.md`, `verification.md`) use the new version.

## Tag

- [ ] `git tag vX.Y.Z && git push origin vX.Y.Z`
- [ ] `release.yml` finished green: version check, tests, gates, build, attestation, release.

## Verify from a clean shell

```sh
curl -sLO https://github.com/mentu-ai/mentu-recipes/releases/download/vX.Y.Z/mentu-recipes-macos-arm64
curl -sLO https://github.com/mentu-ai/mentu-recipes/releases/download/vX.Y.Z/checksums.txt
shasum -a 256 -c checksums.txt --ignore-missing
gh attestation verify mentu-recipes-macos-arm64 --repo mentu-ai/mentu-recipes
chmod +x mentu-recipes-macos-arm64 && ./mentu-recipes-macos-arm64 --version
```

- [ ] Checksums match, attestation verifies, `--version` prints the tag's version.

## Channels

- [ ] Tap: bump `Formula/mentu-recipes-bin.rb` (version, both SHA-256 values); `brew install mentu-ai/tap/mentu-recipes-bin` on a clean machine; `brew test mentu-recipes-bin`.
- [ ] Package channels (cask, `get.mentu.ai`): only if this release produced a notarized `.pkg`. Register it in the release manifest and bump the cask. Otherwise leave both untouched.

## Docs and site

- [ ] `VERIFICATION.md`: paste the real transcript from the clean-shell verification above.
- [ ] Docs site: update the pages that name the version, rebuild, deploy, and confirm the live install page shows the new version.
- [ ] Release notes read correctly on the GitHub release page.

## After

- [ ] Record the release in the internal workspace context.
- [ ] Open the next version's `Version.swift` bump only when the next release is being prepared, so `main` never claims a version that was not published.
