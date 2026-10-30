#!/usr/bin/env bash
# deploy_airgap.sh — run on the OFFLINE target. Verifies, then loads, then starts. No network used.
#
# Usage:  ./deploy_airgap.sh release_v1.4.2.tar.gz [INSTALL_ROOT]     (default /opt/eoir)
#         ./deploy_airgap.sh --rollback [INSTALL_ROOT]                 (switch back to previous release)
set -euo pipefail

PROJECT="eoir"
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need docker; need sha256sum; need tar
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"

start_stack() {   # $1 = release dir
  cd "$1"
  [ -f .env ] || [ -f "$INSTALL_ROOT/.env" ] || die "no .env found. Create $INSTALL_ROOT/.env from .env.example first"
  [ -f .env ] || ln -sf "$INSTALL_ROOT/.env" .env
  export RELEASE_VERSION
  RELEASE_VERSION="$(sed -n 's/^version=//p' BUILD_INFO)"
  # --no-build / --pull never => guaranteed zero network use
  docker compose -p "$PROJECT" up -d --no-build --pull never --remove-orphans
  echo "[..] waiting for http://localhost:8000/health (max 90s)"
  for _ in $(seq 1 45); do
    if curl -fsS http://localhost:8000/health 2>/dev/null | grep -q '"worker_ready": *true'; then
      echo "[ok] stack healthy"; docker compose -p "$PROJECT" ps; return 0
    fi
    sleep 2
  done
  docker compose -p "$PROJECT" ps; docker compose -p "$PROJECT" logs --tail=30 inference_worker || true
  return 1
}

# ---------------------------------------------------------------- rollback mode
if [ "${1:-}" = "--rollback" ]; then
  INSTALL_ROOT="${2:-/opt/eoir}"
  [ -L "$INSTALL_ROOT/previous" ] || die "no previous release recorded in $INSTALL_ROOT"
  PREV="$(readlink -f "$INSTALL_ROOT/previous")"; CUR="$(readlink -f "$INSTALL_ROOT/current")"
  ( cd "$PREV" && sha256sum --quiet -c SHA256SUMS ) || die "previous release failed checksum — do not use"
  ln -sfn "$PREV" "$INSTALL_ROOT/current"; ln -sfn "$CUR" "$INSTALL_ROOT/previous"
  start_stack "$PREV" && echo "[done] rolled back to $(basename "$PREV")"
  exit $?
fi

BUNDLE="${1:-}"; INSTALL_ROOT="${2:-/opt/eoir}"
[ -f "$BUNDLE" ] || die "usage: $0 release_vX.Y.Z.tar.gz [INSTALL_ROOT]"
need curl

# ---- 1. Transport integrity (detached checksum, if shipped alongside) ------------
if [ -f "${BUNDLE}.sha256" ]; then
  ( cd "$(dirname "$BUNDLE")" && sha256sum --quiet -c "$(basename "$BUNDLE").sha256" ) \
    || die "tarball checksum mismatch — bundle damaged or tampered in transit"
  echo "[ok] tarball checksum"
fi

# ---- 2. Extract to a staging dir; nothing is loaded or started yet ---------------
mkdir -p "$INSTALL_ROOT/releases"
STAGE="$(mktemp -d "$INSTALL_ROOT/releases/.staging.XXXXXX")"; trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$BUNDLE" -C "$STAGE"
REL_NAME="$(ls "$STAGE")"; [ "$(echo "$REL_NAME" | wc -l)" = 1 ] || die "unexpected bundle layout"
SRC="$STAGE/$REL_NAME"

# ---- 3. Verify SHA256SUMS BEFORE docker load / compose up ------------------------
cd "$SRC"
[ -f SHA256SUMS ] || die "SHA256SUMS missing — refusing to deploy"
sha256sum --quiet -c SHA256SUMS || die "SHA256SUMS verification FAILED — nothing was loaded"
# completeness: every file in the bundle must be listed (no smuggled extras)
EXTRA="$(find . -type f ! -name SHA256SUMS | LC_ALL=C sort | diff - <(awk '{print $2}' SHA256SUMS | LC_ALL=C sort) || true)"
[ -z "$EXTRA" ] || die "bundle contents differ from SHA256SUMS: $EXTRA"
echo "[ok] SHA256SUMS verified ($(wc -l < SHA256SUMS) files)"

# ---- 4. Architecture guard (x86_64 image on Jetson, or vice-versa, would fail) ---
BP="$(sed -n 's#^platform=linux/##p' BUILD_INFO)"
case "$(uname -m)" in x86_64) HA=amd64;; aarch64|arm64) HA=arm64;; *) HA=unknown;; esac
[ "$BP" = "$HA" ] || die "bundle is built for $BP but this host is $HA"

# ---- 4b. Secrets contract: .env must exist on the target BEFORE anything changes --
[ -f "$INSTALL_ROOT/.env" ] || die "create $INSTALL_ROOT/.env first (template: .env.example inside the bundle; secrets are never bundled)"

# ---- 5. Promote staging -> releases/<name>, keep old one for rollback ------------
DEST="$INSTALL_ROOT/releases/$REL_NAME"
[ ! -e "$DEST" ] || die "$DEST already exists (re-deploys must use a new version)"
mv "$SRC" "$DEST"; cd "$DEST"
[ -L "$INSTALL_ROOT/current" ] && ln -sfn "$(readlink -f "$INSTALL_ROOT/current")" "$INSTALL_ROOT/previous"

# ---- 6. Load images (local file only), start stack -------------------------------
docker load -i images/images.tar
ln -sfn "$DEST" "$INSTALL_ROOT/current"
if start_stack "$DEST"; then
  echo "[done] $REL_NAME deployed. Roll back with: $0 --rollback $INSTALL_ROOT"
else
  echo "[FAIL] new release unhealthy — run: $0 --rollback $INSTALL_ROOT" >&2; exit 1
fi
