#!/usr/bin/env bash
set -Eeuo pipefail

BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
missing=()

for command_name in docker git bash python3 file sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done

if [[ "${#missing[@]}" -gt 0 ]]; then
  printf 'Missing build prerequisites:\n' >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "Install the missing packages with your host operating system's package manager." >&2
  exit 1
fi

docker info >/dev/null 2>&1 || {
  echo "Docker is installed, but its daemon is not running or this user lacks access." >&2
  exit 1
}

available_kb="$(df -Pk "$BASE" | awk 'NR==2 {print $4}')"
available_gib=$((available_kb / 1024 / 1024))

echo "MechOS ArchISO build host is ready."
echo "Docker: $(docker --version)"
echo "Free disk space: ${available_gib} GiB"

# The fully offline installer bundles the package closure; MECHOS_OFFLINE_REPO=0
# builds the smaller online-install ISO.
required_gib=80
[[ "${MECHOS_OFFLINE_REPO:-1}" == "0" ]] && required_gib=45
if [[ "$available_gib" -lt "$required_gib" ]]; then
  echo "Warning: this ISO build requires at least ${required_gib} GiB free." >&2
  exit 1
fi
