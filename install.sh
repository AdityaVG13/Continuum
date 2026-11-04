#!/bin/sh
# Continuum installer for Apple silicon Macs.
#
#   curl -fsSL https://github.com/AdityaVG13/Continuum/releases/latest/download/install.sh | sh
#
# Downloads the latest release archive, checks it against the release's
# SHA256SUMS.txt, and installs bin/continuum plus its prompts and schemas under
# PREFIX (default /usr/local, already on PATH; sudo is asked for only when that
# directory is not writable). Then type `continuum`. Set CONTINUUM_VERSION=v0.2.0
# to pin a release.
set -eu

REPO="AdityaVG13/Continuum"
ASSET="continuum-macos-arm64.tar.gz"
UA="OpenAI File Downloader, XaiImageApiFetch/1.0"
PREFIX="${PREFIX:-/usr/local}"
VERSION="${CONTINUUM_VERSION:-latest}"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "continuum: this release is built for Apple silicon Macs (macOS arm64) only." >&2
    exit 1
fi

if [ -n "${CONTINUUM_BASE_URL:-}" ]; then
    BASE="$CONTINUUM_BASE_URL"
elif [ "$VERSION" = "latest" ]; then
    BASE="https://github.com/$REPO/releases/latest/download"
else
    BASE="https://github.com/$REPO/releases/download/$VERSION"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/continuum-install.XXXXXX")"
trap 'rm -r -f "$WORK"' EXIT INT TERM

echo "Downloading Continuum ($VERSION)..."
curl -fsSL -A "$UA" -o "$WORK/$ASSET" "$BASE/$ASSET"
curl -fsSL -A "$UA" -o "$WORK/SHA256SUMS.txt" "$BASE/SHA256SUMS.txt"

expected="$(awk -v f="$ASSET" '$2 == f { print $1 }' "$WORK/SHA256SUMS.txt")"
actual="$(shasum -a 256 "$WORK/$ASSET" | awk '{ print $1 }')"
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "continuum: checksum mismatch for $ASSET; nothing was installed." >&2
    exit 1
fi

tar -xzf "$WORK/$ASSET" -C "$WORK"
ROOT="$WORK/continuum-macos-arm64"
[ -x "$ROOT/bin/continuum" ] || { echo "continuum: archive is missing bin/continuum." >&2; exit 1; }

SUDO=""
if ! mkdir -p "$PREFIX/bin" "$PREFIX/share" 2>/dev/null || [ ! -w "$PREFIX/bin" ] || [ ! -w "$PREFIX/share" ]; then
    echo "Installing into $PREFIX needs your Mac password once."
    SUDO="sudo"
    $SUDO mkdir -p "$PREFIX/bin" "$PREFIX/share"
fi

$SUDO mkdir -p "$PREFIX/share/continuum"
$SUDO cp -R "$ROOT/share/continuum/." "$PREFIX/share/continuum/"
$SUDO install -m 0755 "$ROOT/bin/continuum" "$PREFIX/bin/continuum"

echo
"$PREFIX/bin/continuum" --version
# An older copy earlier on PATH (e.g. ~/.local/bin from a checkout's make
# install) would shadow this one and run against stale prompts.
found="$(command -v continuum 2>/dev/null || true)"
if [ -n "$found" ] && [ "$found" != "$PREFIX/bin/continuum" ]; then
    echo "Warning: typing continuum currently runs $found ($("$found" --version </dev/null 2>/dev/null || echo unknown version))."
    echo "That older copy comes first on your PATH. Remove it, or run $PREFIX/bin/continuum."
fi
case ":$PATH:" in
    *":$PREFIX/bin:"*) echo "Installed. Type: continuum" ;;
    *) echo "Installed to $PREFIX/bin/continuum (not on your PATH). Run it with: $PREFIX/bin/continuum" ;;
esac
