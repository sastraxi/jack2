#!/usr/bin/env bash
# Build a macOS .pkg installer for the sastraxi/jack2 fork.
#
# The fork carries the pi-stomp/JackBridge patches on top of upstream
# v1.9.22 (PI controller reset, master-side and slave-side multicast
# interface pin via JACK_NETJACK_MULTICAST_IF). See ChangeLog.rst for
# the full commit list.
#
# Usage:
#   ./build-macos-pkg.sh [version]
#
# Output:
#   build/jack2-<version>.pkg
#
# The pkg installs to /usr/local — the manual-install prefix on Apple
# Silicon Macs (Homebrew is at /opt/homebrew, the two are intentionally
# separate). On Intel Macs you'd typically also use /usr/local.
#
# Requirements:
#   - Xcode command line tools (clang, pkgbuild)
#   - Homebrew aften: `brew install aften` (for the configure-time
#     `conf.check(lib='aften')` on macOS; we don't actually encode AC-3
#     in the netJACK2 path but the check is mandatory in v1.9.22's wscript)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
STAGING="$BUILD/staging-pkg"
PKG_OUT_DIR="$BUILD"

# Version: explicit arg wins, else derived from the fork's commit count
# past v1.9.22 + a short SHA. e.g. 1.9.22+sastraxi.3.gb3bfc408
if [ $# -ge 1 ]; then
    VERSION="$1"
else
    BASE="1.9.22"
    COUNT=$(git rev-list --count "v1.9.22..HEAD" 2>/dev/null || echo "0")
    SHORT=$(git rev-parse --short HEAD)
    VERSION="${BASE}+sastraxi.${COUNT}.g${SHORT}"
fi

echo "==> jack2 fork @ $(git rev-parse --short HEAD) ($(git log -1 --pretty=%s))"
echo "==> version: $VERSION"

mkdir -p "$BUILD" "$STAGING"

# Refuse to bake in half-finished edits.
if [ -n "$(git status --porcelain -- ':!build/' ':!build-macos-pkg.sh')" ]; then
    echo "error: jack2 working tree is dirty outside build/; commit or stash first" >&2
    git status --short >&2
    exit 1
fi

echo
echo "==> configure + build (with aften on CPPFLAGS/LDFLAGS)"
# aften is at /opt/homebrew on Apple Silicon. Both CPPFLAGS and LDFLAGS
# are needed: the configure check needs the lib to be findable, and
# coreaudio/JackAC3Encoder.h includes <aften/aften.h> unconditionally.
CPPFLAGS="-I/opt/homebrew/include" \
LDFLAGS="-L/opt/homebrew/lib" \
    python3 ./waf configure --prefix=/usr/local

CPPFLAGS="-I/opt/homebrew/include" \
LDFLAGS="-L/opt/homebrew/lib" \
    python3 ./waf build

echo
echo "==> install to staging dir"
# Install to a private staging tree under the build dir (user-owned,
# so no sudo needed). /usr/local must still be the configure prefix
# so paths baked into dylibs (LC_LOAD_DYLIB) resolve correctly on
# the install target; --destdir just redirects the file copies.
rm -rf "$STAGING"
mkdir -p "$STAGING"
python3 ./waf install --destdir="$STAGING"

echo
echo "==> build the .pkg"
PKG_ID="com.sastraxi.jack2"
PKG_OUT="$PKG_OUT_DIR/jack2-${VERSION}.pkg"

# --root: the directory whose contents become the payload (so the
#         payload layout matches the install-location layout, /usr/local/...)
# --install-location: the absolute path the payload is rooted at on
#         the target. The pkg is relocatable to any prefix only if we
#         don't hardcode paths in dylibs, but our jackd and dylibs use
#         absolute @rpath-style install_names, so /usr/local is the
#         only sensible install-location for this fork.
pkgbuild \
    --root "$STAGING" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location /usr/local \
    --ownership recommended \
    "$PKG_OUT"

echo
echo "==> done"
ls -la "$PKG_OUT"
echo
echo "Inspect with:"
echo "  pkgutil --payload-files $PKG_OUT | head -20"
echo
echo "Install with:"
echo "  sudo installer -pkg $PKG_OUT -target /"
echo
echo "Verify after install:"
echo "  /usr/local/bin/jackd --version"
echo "  strings /usr/local/lib/jack/netmanager.so | grep JACK_NETJACK_MULTICAST_IF"
