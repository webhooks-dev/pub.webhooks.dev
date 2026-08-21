#!/bin/sh
# install.sh — install the whk consumer binaries (whk, whkd, whk-mcp) from the
# latest GitHub release of webhooks-dev/pub.webhooks.dev.
#
#   curl -fsSL https://raw.githubusercontent.com/webhooks-dev/pub.webhooks.dev/main/install.sh | sh
#
# Behavior:
#   - macOS (arm64, x86_64) and Linux (x86_64, arm64) only; anything else is
#     refused with a message. Windows is not shipped yet — see the README.
#   - Downloads the release tarball AND SHA256SUMS, then verifies the checksum
#     BEFORE installing. A mismatch or a missing checksum entry is a hard fail.
#   - Installs to $PREFIX/bin (default PREFIX: ~/.local). No sudo. Re-running
#     overwrites in place, so this is also the upgrade path.

set -eu

REPO="webhooks-dev/pub.webhooks.dev"
REPO_URL="https://github.com/$REPO"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

# --- platform detection ------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Darwin) TARGET_OS="apple-darwin" ;;
    Linux) TARGET_OS="unknown-linux-gnu" ;;
    MINGW* | MSYS* | CYGWIN*)
        die "Windows builds are not shipped yet (no signing identity). See $REPO_URL#supported-platforms"
        ;;
    *)
        die "unsupported OS: $OS (supported: Darwin, Linux)"
        ;;
esac

case "$ARCH" in
    arm64 | aarch64) TARGET_ARCH="aarch64" ;;
    x86_64 | amd64) TARGET_ARCH="x86_64" ;;
    *)
        die "unsupported architecture: $ARCH (supported: arm64/aarch64, x86_64/amd64)"
        ;;
esac

TARGET="$TARGET_ARCH-$TARGET_OS"

# --- resolve the latest release via the releases/latest redirect --------------
LATEST_URL="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$REPO_URL/releases/latest")" ||
    die "could not resolve the latest release (is $REPO_URL reachable?)"
TAG="${LATEST_URL##*/}"
case "$TAG" in
    v[0-9]*) ;;
    *) die "could not parse a release tag from: $LATEST_URL" ;;
esac
VERSION="${TAG#v}"

ASSET="whk-$VERSION-$TARGET.tar.gz"
BASE="$REPO_URL/releases/download/$TAG"

say "whk $VERSION ($TARGET)"

# --- download -----------------------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/whk-install.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM

say "downloading $ASSET ..."
curl -fsSL -o "$TMP/$ASSET" "$BASE/$ASSET" ||
    die "download failed: $BASE/$ASSET (no build for $TARGET in $TAG?)"
curl -fsSL -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS" ||
    die "download failed: $BASE/SHA256SUMS"

# --- verify BEFORE installing (hard fail on any mismatch) ---------------------
awk -v f="$ASSET" '$2 == f || $2 == "*" f { print }' "$TMP/SHA256SUMS" >"$TMP/CHECK"
[ -s "$TMP/CHECK" ] || die "SHA256SUMS has no entry for $ASSET — refusing to install"

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$TMP" && sha256sum -c CHECK >/dev/null 2>&1) ||
        die "checksum MISMATCH for $ASSET — refusing to install"
elif command -v shasum >/dev/null 2>&1; then
    (cd "$TMP" && shasum -a 256 -c CHECK >/dev/null 2>&1) ||
        die "checksum MISMATCH for $ASSET — refusing to install"
else
    die "neither sha256sum nor shasum found — cannot verify $ASSET, refusing to install"
fi
say "checksum verified"

# --- install ------------------------------------------------------------------
mkdir -p "$TMP/x"
tar -xzf "$TMP/$ASSET" -C "$TMP/x" || die "could not extract $ASSET"

for b in whk whkd whk-mcp; do
    [ -f "$TMP/x/$b" ] || die "tarball is missing '$b' (unexpected layout)"
done

mkdir -p "$BIN_DIR" || die "could not create $BIN_DIR"
for b in whk whkd whk-mcp; do
    install -m 0755 "$TMP/x/$b" "$BIN_DIR/$b" || die "could not install $b to $BIN_DIR"
done

say "installed whk, whkd, whk-mcp $VERSION to $BIN_DIR"
say "note: an already-running whkd keeps its old binary until restarted:"
say "  whk daemon stop && whk daemon start"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        say ""
        say "NOTE: $BIN_DIR is not on your PATH. Add it, e.g.:"
        say "  export PATH=\"$BIN_DIR:\$PATH\""
        ;;
esac
