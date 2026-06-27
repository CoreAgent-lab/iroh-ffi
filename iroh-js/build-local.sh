#!/usr/bin/env bash
#
# build-local.sh — build all non-Windows @number0/iroh napi targets on a single
# macOS (Apple Silicon) host, producing portable, verified .node binaries for an
# npm release. Windows targets are NOT built here (they require a Windows host /
# CI) — see the note at the end.
#
# Strategy (derived from real cross/verify findings):
#   - darwin (aarch64-apple-darwin): native `napi build` (host arch).
#   - linux musl: `napi build --cross-compile` (zig). musl is statically linked,
#     so there is no glibc floor to worry about.
#   - linux gnu: built with `cargo zigbuild` pinned to an OLD glibc floor for
#     portability, then the cdylib is renamed to the napi .node filename.
#     We bypass `napi build` for gnu because napi's copyArtifact step cannot
#     handle the `<triple>.<glibc>` target suffix that cargo-zigbuild needs.
#     Without the pin, zig defaults armv7-gnueabihf to glibc 2.34 (too new —
#     fails to load on Debian 11 / RHEL 8 / etc.).
#
# Requirements (install once):
#   - Rust + rustup, with the linux targets added (the script adds them).
#   - zig + cargo-zigbuild  (brew install zig; cargo install cargo-zigbuild)
#   - Node + corepack/yarn, deps installed in iroh-js (`yarn install`).
#
# Usage:
#   ./build-local.sh                 # build + verify all 7 non-windows targets
#   ./build-local.sh --assemble      # also copy .node into npm/<platform>/ dirs
#   GLIBC_FLOOR=2.28 ./build-local.sh # override the gnu glibc floor (default 2.17)

set -euo pipefail

# --- locate dirs ---------------------------------------------------------------
JS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../iroh-ffi/iroh-js
WS_DIR="$(cd "$JS_DIR/.." && pwd)"                        # workspace root
CDYLIB="libnumber0_iroh.so"                              # crate `number0_iroh` cdylib
GLIBC_FLOOR="${GLIBC_FLOOR:-2.17}"                        # portable manylinux2014 floor
ASSEMBLE=0
[ "${1:-}" = "--assemble" ] && ASSEMBLE=1

export PATH="$HOME/.cargo/bin:$PATH"
# Strip gnu builds at link time (the manual path doesn't go through napi --strip).
export CARGO_PROFILE_RELEASE_STRIP=symbols

cd "$JS_DIR"

# triple -> napi platform name (used for the iroh.<platform>.node filename)
DARWIN="aarch64-apple-darwin"
GNU_TARGETS=(
  "x86_64-unknown-linux-gnu:linux-x64-gnu"
  "aarch64-unknown-linux-gnu:linux-arm64-gnu"
  "armv7-unknown-linux-gnueabihf:linux-arm-gnueabihf"
)
MUSL_TARGETS=(
  "x86_64-unknown-linux-musl:linux-x64-musl"
  "aarch64-unknown-linux-musl:linux-arm64-musl"
  "armv7-unknown-linux-musleabihf:linux-arm-musleabihf"
)

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- ensure rust targets -------------------------------------------------------
log "Ensuring rust targets are installed"
for entry in "$DARWIN:darwin-arm64" "${GNU_TARGETS[@]}" "${MUSL_TARGETS[@]}"; do
  t="${entry%%:*}"
  rustup target add "$t" >/dev/null 2>&1 || true
done

# --- 1) darwin native ----------------------------------------------------------
log "Building darwin (native): $DARWIN"
yarn napi build --platform --release --strip --target "$DARWIN"

# --- 2) musl (static libc) via napi + zig --------------------------------------
for entry in "${MUSL_TARGETS[@]}"; do
  t="${entry%%:*}"
  log "Building musl: $t"
  yarn napi build --platform --release --strip --target "$t" --cross-compile
done

# --- 3) gnu (pinned glibc) via cargo-zigbuild + manual rename ------------------
for entry in "${GNU_TARGETS[@]}"; do
  t="${entry%%:*}"; plat="${entry##*:}"
  log "Building gnu (glibc $GLIBC_FLOOR): $t"
  cargo zigbuild --release --target "${t}.${GLIBC_FLOOR}"
  cp "$WS_DIR/target/${t}/release/${CDYLIB}" "$JS_DIR/iroh.${plat}.node"
done

# --- verify --------------------------------------------------------------------
log "Verifying artifacts (arch + glibc floor)"
fail=0
verify() { # platform expected-arch-substring is-gnu
  local plat="$1" want="$2" gnu="$3" f="iroh.$1.node"
  if [ ! -f "$f" ]; then echo "MISSING  $f"; fail=1; return; fi
  local arch; arch="$(file -b "$f")"
  local glibc=""
  if [ "$gnu" = "1" ]; then
    glibc="$(strings "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -V | tail -1)"
  fi
  if echo "$arch" | grep -q "$want"; then
    printf '  ok  %-26s %s %s\n' "$plat" "$want" "$glibc"
  else
    printf '  XX  %-26s got: %s\n' "$plat" "$arch"; fail=1
  fi
}
verify darwin-arm64        "arm64"             0
verify linux-x64-gnu       "x86-64"            1
verify linux-arm64-gnu     "aarch64"           1
verify linux-arm-gnueabihf "ARM"               1
verify linux-x64-musl      "x86-64"            0
verify linux-arm64-musl    "aarch64"           0
verify linux-arm-musleabihf "ARM"              0

# warn if any gnu floor exceeds the requested floor
for entry in "${GNU_TARGETS[@]}"; do
  plat="${entry##*:}"; f="iroh.${plat}.node"
  hi="$(strings "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -V | tail -1 | sed 's/GLIBC_//')"
  if [ -n "$hi" ] && [ "$(printf '%s\n%s\n' "$hi" "$GLIBC_FLOOR" | sort -V | tail -1)" != "$GLIBC_FLOOR" ]; then
    echo "  !!  $plat needs GLIBC_$hi > floor $GLIBC_FLOOR (portability reduced)"; fail=1
  fi
done

# --- optional assembly into npm/ subpackages -----------------------------------
if [ "$ASSEMBLE" = "1" ]; then
  log "Assembling .node into npm/<platform>/ (napi artifacts)"
  yarn napi artifacts --output-dir . --npm-dir ./npm
fi

log "Built .node files"
ls -1 iroh.*.node

if [ "$fail" = "0" ]; then
  log "All 7 non-windows targets built & verified ✅"
else
  log "Completed WITH ISSUES ❌ (see XX/!! above)"; exit 1
fi

cat <<'NOTE'

Next steps for a full npm publish:
  - Windows (aarch64/x86_64-pc-windows-msvc) is NOT built here — build it on a
    Windows runner (the repo's ci_js.yml does this) and collect those .node too.
  - With ALL targets present, run `napi prepublish` + `npm publish` (the repo's
    CI publish job uses npm Trusted Publishing / OIDC).
  - This script only produces+verifies the non-windows binaries; it does not publish.
NOTE
