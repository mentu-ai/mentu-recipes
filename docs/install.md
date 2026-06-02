# Install

## macOS Package

Install the signed and notarized macOS package:

```sh
brew install --cask mentu-ai/tap/mentu-recipes
```

The Homebrew cask:

1. Downloads the signed package from the GitHub release.
2. Verifies the SHA-256 checksum.
3. Installs `mentu-recipes` to `/usr/local/bin/mentu-recipes`.

## Direct Release Package

If you prefer not to use the hosted installer, install the signed release
package directly:

```sh
VERSION=0.1.0
PKG="mentu-recipes-${VERSION}-macos-arm64.pkg"
BASE="https://github.com/mentu-ai/mentu-recipes/releases/download/v${VERSION}"
curl -fL "$BASE/$PKG" -o "$PKG"
echo "a6ab0e0125c90cb1d57361972dc9eeada229a7d9b4c8d3599388c1ada6cee560  $PKG" | shasum -a 256 -c -
spctl -a -vv -t install "$PKG"
sudo installer -pkg "$PKG" -target /
```

## Build From Source

```sh
git clone https://github.com/mentu-ai/mentu-recipes.git
cd mentu-recipes
swift build
swift test
```

Run from source:

```sh
swift run mentu-recipes adapters
```

## Requirements

- macOS on Apple Silicon for the packaged release
- Swift toolchain for source builds
- `curl` for the installer
- `plutil`, `shasum`, and `spctl` for installer verification

## Verify The Installed Binary

```sh
mentu-recipes adapters
mentu-recipes init
mentu-recipes check shell-smoke
```
