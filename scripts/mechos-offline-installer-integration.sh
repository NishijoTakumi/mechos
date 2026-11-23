#!/usr/bin/env bash
# MECHOS_OFFLINE_INSTALLER_INTEGRATION_V1
#
# Make Clean Install fully offline: patch the native installer helper to install
# from a package repository bundled in the Live image, then build that
# repository from the helper's own package list so the two can never drift.
#
# Runs inside the ArchISO build container, last, just before mkarchiso.
#   MECHOS_OFFLINE_REPO=0   skip (leaves the online-install behaviour)
set -Eeuo pipefail

PHASE="${1:-final}"
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${MECHOS_AIROOTFS:-/workspace/archlive/airootfs}"
HELPER="$ROOT/usr/local/libexec/mechos-native-install-helper"
REPO_DIR="$ROOT/usr/share/mechos/offline-repo"
WORK="${MECHOS_OFFLINE_WORK:-/var/tmp/mechos-offline-work}"

log() { printf '[MechOS Offline Installer] %s\n' "$*"; }
fail() { printf '[MechOS Offline Installer] ERROR: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2154  # rc is assigned inside the trap string
trap 'rc=$?; printf "[MechOS Offline Installer] ERROR: line %s failed: %s (exit %s)\n" "$LINENO" "$BASH_COMMAND" "$rc" >&2' ERR

[ "$PHASE" = "final" ] || exit 0

if [ "${MECHOS_OFFLINE_REPO:-1}" = "0" ]; then
  log "MECHOS_OFFLINE_REPO=0: skipping; this ISO's installer will need a network."
  exit 0
fi

[ -f "$HELPER" ] || fail "native installer helper is missing: $HELPER"
command -v pacman >/dev/null 2>&1 || fail "pacman is required (run inside the Arch build container)"
command -v repo-add >/dev/null 2>&1 || fail "repo-add is required (pacman-package tooling missing)"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

# 1. Point the installer at the bundled repo (fails loudly if an anchor drifted).
python3 "$SCRIPTS/patch-mechos-offline-helper.py" "$HELPER"
bash -n "$HELPER" || fail "native installer helper syntax failed after offline patch"
grep -Fq 'MECHOS_OFFLINE_INSTALL_V1' "$HELPER" || fail "offline install marker missing from helper"

# 2. Derive the package list from the patched helper: the PACKAGES array plus
#    anything appended with PACKAGES+=(...) (NVIDIA drivers).
mkdir -p "$WORK"
LIST="$WORK/packages.list"
python3 - "$HELPER" "$LIST" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"^PACKAGES=\(\n(.*?)\n\)\n", text, re.S | re.M)
if not m:
    raise SystemExit("PACKAGES array not found in helper")
names = m.group(1).split()
for extra in re.findall(r"PACKAGES\+=\(([^)]*)\)", text):
    names += extra.split()
if len(names) < 50:
    raise SystemExit(f"implausibly small package list ({len(names)}); refusing to continue")
Path(sys.argv[2]).write_text("\n".join(names) + "\n", encoding="utf-8")
print(f"[MechOS Offline Installer] {len(set(names))} install targets")
PY

# 3. Download and lay out the repository inside the Live rootfs.
rm -rf "$REPO_DIR"
mkdir -p "$(dirname "$REPO_DIR")"
python3 "$SCRIPTS/mechos-offline-repo.py" --packages "$LIST" --out "$REPO_DIR" --work "$WORK/build"
rm -rf "$WORK"

# 4. Verify what mkarchiso is about to ship.
python3 - "$REPO_DIR" "$HELPER" <<'PY'
import json, re, sys
from pathlib import Path
repo, helper = Path(sys.argv[1]), Path(sys.argv[2])
man = json.loads((repo / "manifest.json").read_text(encoding="utf-8"))
need = set(re.search(r"^PACKAGES=\(\n(.*?)\n\)\n", helper.read_text(encoding="utf-8"), re.S | re.M).group(1).split())
missing_targets = need - set(man["targets"])
if missing_targets:
    raise SystemExit(f"offline repo was not built for: {sorted(missing_targets)}")
names = {p["name"] for r in man["packages"].values() for p in r}
for core in ("base", "linux", "linux-firmware", "grub", "networkmanager", "plasma-meta", "steam"):
    if core not in names:
        raise SystemExit(f"offline repo is missing essential package: {core}")
for repo_name in ("core", "extra", "multilib"):
    d = repo / repo_name / "os" / "x86_64"
    if not (d / f"{repo_name}.db").is_file():
        raise SystemExit(f"missing database: {d}/{repo_name}.db")
    for p in man["packages"][repo_name]:
        f = d / p["file"]
        if not f.is_file() or f.stat().st_size == 0:
            raise SystemExit(f"missing package file: {f}")
print(f"[MechOS Offline Installer] verified {man['package_count']} packages, {man['total_bytes'] / 2**30:.2f} GiB")
PY

log "Clean Install is now fully offline; repository bundled at /usr/share/mechos/offline-repo"
