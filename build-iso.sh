#!/usr/bin/env bash
set -Eeuo pipefail

BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="$BASE/out"
IMAGE="${MECHOS_ARCH_IMAGE:-archlinux:latest}"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required. Run ./scripts/setup-build-host.sh for a prerequisite check." >&2
  exit 127
}

docker info >/dev/null 2>&1 || {
  echo "Docker is installed but the daemon is unavailable to this user." >&2
  exit 1
}

# The fully offline installer bundles the whole package closure (several GiB,
# held in the build tree, the ArchISO work copy and the SquashFS), so it needs
# considerably more room. MECHOS_OFFLINE_REPO=0 builds the smaller online-install ISO.
MECHOS_OFFLINE_REPO="${MECHOS_OFFLINE_REPO:-1}"
required_gib=80
[[ "$MECHOS_OFFLINE_REPO" == "0" ]] && required_gib=45
available_kb="$(df -Pk "$BASE" | awk 'NR==2 {print $4}')"
required_kb=$((required_gib * 1024 * 1024))
if [[ -n "$available_kb" && "$available_kb" -lt "$required_kb" ]]; then
  echo "At least ${required_gib} GiB of free disk space is required for this ArchISO build." >&2
  exit 1
fi

mkdir -p "$OUT"

docker run --rm --privileged \
  -e "MECHOS_HOST_UID=$(id -u)" \
  -e "MECHOS_HOST_GID=$(id -g)" \
  -e "MECHOS_HARDWARE_TARGET_VERSION=${MECHOS_HARDWARE_TARGET_VERSION:-}" \
  -e "MECHOS_OFFLINE_REPO=${MECHOS_OFFLINE_REPO}" \
  -v "$BASE:/workspace" \
  -w /workspace \
  "$IMAGE" \
  bash -lc '
    set -Eeuo pipefail
    bash /workspace/scripts/patch-mechos-live-autologin-partitionmanager.sh /workspace/scripts/build-mechos-archiso.sh
    bash /workspace/scripts/build-mechos-archiso.sh
    chown -R "${MECHOS_HOST_UID}:${MECHOS_HOST_GID}" /workspace/out
  '

ISO="$(find "$OUT" -maxdepth 2 -type f -name '*.iso' -print -quit)"
[[ -n "$ISO" && -s "$ISO" ]] || {
  echo "The build completed without producing a non-empty ISO." >&2
  exit 1
}
[[ -s "$ISO.sha256" ]] || {
  echo "The ISO checksum file is missing: $ISO.sha256" >&2
  exit 1
}

(
  cd "$(dirname "$ISO")"
  sha256sum -c "$(basename "$ISO").sha256"
)

echo "MechOS ISO ready: $ISO"
