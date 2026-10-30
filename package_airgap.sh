#!/usr/bin/env bash
# package_airgap.sh — run on an INTERNET-CONNECTED build host (e.g. your EC2).
# Produces release_v<VERSION>.tar.gz containing images, compose config, models/,
# deploy script and a SHA256SUMS manifest covering every file.
#
# Usage:  ./package_airgap.sh [VERSION]            (default 1.4.2)
#         ARCH=arm64 ./package_airgap.sh           (cross-build for Jetson, needs buildx+qemu)
set -euo pipefail

VERSION="${1:-1.4.2}"
PROJECT="eoir"                       # fixed compose project name => same image names on every host
RELEASE="release_v${VERSION}"
OUT_DIR="$(pwd)"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
ARCH="${ARCH:-}"                     # amd64 | arm64 | empty = host arch

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

need docker; need sha256sum; need tar
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"
cd "$REPO_DIR"

# ---- 1. Pre-flight: refuse to ship a model that fails its own manifest ----------
ENGINE="models/eo_detector_fp16.engine"
MANIFEST="models/manifest.json"
[ -f "$ENGINE" ] && [ -f "$MANIFEST" ] || die "models/ is missing engine or manifest"
EXPECTED="$(sed -n 's/.*"sha256"[^"]*"\([0-9a-fA-F]\{64\}\)".*/\1/p' "$MANIFEST" | tr 'A-F' 'a-f')"
ACTUAL="$(sha256sum "$ENGINE" | cut -d' ' -f1)"
[ -n "$EXPECTED" ] || die "no sha256 found in $MANIFEST"
[ "$EXPECTED" = "$ACTUAL" ] || die "engine does not match manifest (expected $EXPECTED, got $ACTUAL)"
MV="$(sed -n 's/.*"version"[^"]*"\([^"]*\)".*/\1/p' "$MANIFEST")"
[ "$MV" = "$VERSION" ] || die "manifest version ($MV) != release version ($VERSION)"
echo "[ok] model manifest verified ($ACTUAL)"

# ---- 2. Build + collect images ---------------------------------------------------
# Config comes from .env if present, else the template (secrets are never bundled).
ENV_FILE=".env"; [ -f "$ENV_FILE" ] || ENV_FILE=".env.example"
export RELEASE_VERSION="$VERSION"
[ -n "$ARCH" ] && export DOCKER_DEFAULT_PLATFORM="linux/${ARCH}"
DC="docker compose -p $PROJECT --env-file $ENV_FILE"

$DC build
$DC pull --ignore-buildable 2>/dev/null || true         # postgres etc.
mapfile -t IMAGES < <($DC config --images | sort -u)
[ "${#IMAGES[@]}" -gt 0 ] || die "no images resolved from compose file"
for img in "${IMAGES[@]}"; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img"
done
echo "[ok] images: ${IMAGES[*]}"

# ---- 3. Stage the bundle ---------------------------------------------------------
B="$STAGE/$RELEASE"
mkdir -p "$B/images" "$B/models"
docker save -o "$B/images/images.tar" "${IMAGES[@]}"
cp docker-compose.yml "$B/docker-compose.yml"
cp .env.example "$B/.env.example"                         # template only — NEVER .env
cp -a models/. "$B/models/"
rm -rf "$B/models/.trt_cache"
cp deploy_airgap.sh "$B/deploy_airgap.sh"; chmod 0755 "$B/deploy_airgap.sh"
printf '%s\n' "${IMAGES[@]}" > "$B/images/IMAGES.txt"
cat > "$B/BUILD_INFO" <<INFO
version=$VERSION
project=$PROJECT
platform=$(docker image inspect "${IMAGES[0]}" --format '{{.Os}}/{{.Architecture}}')
built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
INFO

# ---- 4. SHA256SUMS over EVERY file (SHA256SUMS itself cannot hash itself) --------
( cd "$B" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z \
    | xargs -0 sha256sum > SHA256SUMS )
echo "[ok] SHA256SUMS: $(wc -l < "$B/SHA256SUMS") files"

# ---- 5. Create the tarball + detached checksum for transport verification -------
TARBALL="$OUT_DIR/${RELEASE}.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$STAGE" -czf "$TARBALL" "$RELEASE"
( cd "$OUT_DIR" && sha256sum "${RELEASE}.tar.gz" > "${RELEASE}.tar.gz.sha256" )
echo "[done] $TARBALL ($(du -h "$TARBALL" | cut -f1))"
echo "       carry BOTH ${RELEASE}.tar.gz and ${RELEASE}.tar.gz.sha256 to the target, plus deploy_airgap.sh"
