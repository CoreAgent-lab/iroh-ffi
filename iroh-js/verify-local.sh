#!/usr/bin/env bash
#
# verify-local.sh — runtime verification for the .node binaries produced by
# build-local.sh. The build script does STATIC checks (arch + glibc floor);
# this script confirms each binary actually LOADS and passes the test suite on
# its real target platform, via Docker (mirrors the repo's CI test jobs).
#
#   - darwin: run `node --test` natively on the host.
#   - linux: run `node --test` inside the matching Docker image:
#       * gnu  -> node:<tag>-bullseye-slim  (Debian 11, glibc 2.31 — a STRICT
#                 portability floor; if a gnu binary loads here it loads on
#                 anything newer too).
#       * musl -> node:<tag>-alpine.
#       arm64 runs natively on Apple Silicon; x64 via Rosetta; arm/v7 via QEMU.
#
# The test files import `../index.js` (relative) and use node's built-in test
# runner, so NO `yarn install` is needed inside the containers — the whole
# iroh-js dir is mounted and the loader picks the matching local iroh.*.node.
#
# IMPORTANT: do NOT run `multiarch/qemu-user-static --reset` to enable arm
# emulation — it clobbers Docker Desktop's own binfmt handlers and breaks ALL
# containers (even native arch). Docker Desktop ships arm/v7 + amd64 emulation
# out of the box. If arm/v7 ever fails to start, the SAFE fix is:
#     docker run --privileged --rm tonistiigi/binfmt --install arm
#
# Usage:
#   ./verify-local.sh                 # verify all present non-windows targets
#   NODE_TAG=24 ./verify-local.sh     # use a different node major (default 22)

set -uo pipefail   # NOT -e: we want to run every target and report a summary

JS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_TAG="${NODE_TAG:-22}"
cd "$JS_DIR"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
declare -a RESULTS

# Extract "# pass N" / "# fail N" from a node --test run and record a verdict.
record() { # label  output
  local label="$1" out="$2"
  local pass fail
  pass="$(printf '%s\n' "$out" | grep -oE '^# pass [0-9]+' | grep -oE '[0-9]+' | tail -1)"
  fail="$(printf '%s\n' "$out" | grep -oE '^# fail [0-9]+' | grep -oE '[0-9]+' | tail -1)"
  pass="${pass:-0}"; fail="${fail:-?}"
  if [ "$fail" = "0" ] && [ "$pass" != "0" ]; then
    RESULTS+=("ok   $label  ($pass passed)")
  else
    RESULTS+=("FAIL $label  (pass=$pass fail=$fail)")
    printf '%s\n' "$out" | tail -6 | sed 's/^/      /'
  fi
}

# Run the suite inside a container for one linux target.
verify_docker() { # label  platform  image  nodefile
  local label="$1" plat="$2" image="$3" nodefile="$4"
  if [ ! -f "$nodefile" ]; then RESULTS+=("skip $label  (missing $nodefile)"); return; fi
  log "Verifying $label  ($plat, $image)"
  local out
  out="$(docker run --rm --platform "$plat" -v "$JS_DIR":/build -w /build "$image" \
          sh -c 'node --test test/*.mjs' 2>&1)"
  echo "$out" | grep -E '^# (tests|pass|fail)' | sed 's/^/   /'
  record "$label" "$out"
}

# --- darwin: native on host ----------------------------------------------------
if [ -f iroh.darwin-arm64.node ]; then
  log "Verifying darwin-arm64 (native host)"
  out="$(node --test test/*.mjs 2>&1)"
  echo "$out" | grep -E '^# (tests|pass|fail)' | sed 's/^/   /'
  record "darwin-arm64" "$out"
else
  RESULTS+=("skip darwin-arm64  (missing iroh.darwin-arm64.node)")
fi

# --- linux gnu: strict old-glibc floor (bullseye, 2.31) ------------------------
verify_docker "linux-x64-gnu"       linux/amd64  "node:${NODE_TAG}-bullseye-slim" iroh.linux-x64-gnu.node
verify_docker "linux-arm64-gnu"     linux/arm64  "node:${NODE_TAG}-bullseye-slim" iroh.linux-arm64-gnu.node
verify_docker "linux-arm-gnueabihf" linux/arm/v7 "node:${NODE_TAG}-bullseye-slim" iroh.linux-arm-gnueabihf.node

# --- linux musl: alpine --------------------------------------------------------
verify_docker "linux-x64-musl"       linux/amd64  "node:${NODE_TAG}-alpine" iroh.linux-x64-musl.node
verify_docker "linux-arm64-musl"     linux/arm64  "node:${NODE_TAG}-alpine" iroh.linux-arm64-musl.node
verify_docker "linux-arm-musleabihf" linux/arm/v7 "node:${NODE_TAG}-alpine" iroh.linux-arm-musleabihf.node

# --- summary -------------------------------------------------------------------
log "Verification summary"
rc=0
for r in "${RESULTS[@]}"; do
  printf '  %s\n' "$r"
  case "$r" in FAIL*) rc=1;; esac
done
[ "$rc" = 0 ] && log "All present targets passed ✅" || log "Some targets FAILED ❌"
exit $rc
