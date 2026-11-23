#!/usr/bin/env bash
# Source-level validation for the fully offline installer. Needs no Arch tools,
# Docker or network: pacman/repo-add are replaced by small stubs so the
# repository layout logic can be exercised anywhere.
set -Eeuo pipefail

BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
S="$BASE/scripts"
NATIVE="$S/mechos-native-installer-integration.sh"
HARDEN="$S/mechos-live-installer-final-hardening.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "Offline installer validation error: $*" >&2; exit 1; }

bash -n "$S/mechos-offline-installer-integration.sh" || fail "mechos-offline-installer-integration.sh syntax"
for f in mechos-offline-repo.py patch-mechos-offline-helper.py patch-mechos-offline-installer.py; do
  python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$S/$f" || fail "$f syntax"
done
grep -Fq 'MECHOS_OFFLINE_REPO_BUILDER_V1' "$S/mechos-offline-repo.py" || fail "repo builder marker missing"
grep -Fq 'MECHOS_OFFLINE_HELPER_PATCH_V1' "$S/patch-mechos-offline-helper.py" || fail "helper patch marker missing"
grep -Fq 'MECHOS_OFFLINE_INSTALLER_INTEGRATION_V1' "$S/mechos-offline-installer-integration.sh" || fail "integration marker missing"

# --- 1. Helper patch against the real generated helper (with and without the
#        hardening stage's online preflight already applied).
awk "/<<'HELPER_EOF'/{f=1;next} /^HELPER_EOF\$/{f=0} f" "$NATIVE" > "$TMP/helper.pristine"
[ -s "$TMP/helper.pristine" ] || fail "could not extract the native installer helper"
cp "$TMP/helper.pristine" "$TMP/helper.raw"
awk '/python3 - "\$LIBEXEC\/mechos-native-install-helper" <<.PY.$/{f=1;next} /^PY$/{if(f){exit}} f' "$HARDEN" > "$TMP/harden.py"
cp "$TMP/helper.raw" "$TMP/helper.hardened"
[ -s "$TMP/harden.py" ] && python3 -I "$TMP/harden.py" "$TMP/helper.hardened"
grep -Fq 'MECHOS_NATIVE_INSTALL_PREFLIGHT_V1' "$TMP/helper.hardened" || fail "test fixture lost the online preflight"

for variant in raw hardened; do
  h="$TMP/helper.$variant"
  python3 -I "$S/patch-mechos-offline-helper.py" "$h" >/dev/null || fail "helper patch failed on $variant helper"
  bash -n "$h" || fail "patched $variant helper has a syntax error"
  grep -Fq 'MECHOS_OFFLINE_INSTALL_V1' "$h" || fail "marker missing ($variant)"
  grep -Fq 'pacstrap -K -C "$OFFLINE_CONF"' "$h" || fail "pacstrap does not use the offline repo ($variant)"
  grep -Fq 'SigLevel = Never' "$h" || fail "offline signature policy missing ($variant)"
  grep -Fq 'PACKAGES+=(nvidia-open nvidia-utils lib32-nvidia-utils)' "$h" || fail "NVIDIA packages are not part of pacstrap ($variant)"
  [ "$(grep -c '^PACKAGES=($' "$h")" -eq 1 ] || fail "PACKAGES array count wrong ($variant)"
  for online in 'MECHOS_NATIVE_INSTALL_PREFLIGHT_V1' 'installer-pacman-preflight' '"$PACCONF"' 'arch-chroot "$MNT" pacman -S'; do
    ! grep -Fq "$online" "$h" || fail "online step remains in $variant helper: $online"
  done
  # Every network-free check must precede the first destructive command.
  python3 -I - "$h" <<'PY' || fail "offline checks do not precede the wipe ($variant)"
import sys
t = open(sys.argv[1]).read()
wipe = t.index('wipefs --all')
for needle in ('OFFLINE_CONF" <<OFFLINE_CONF_EOF', "-Sp --print-format '%r %f'", 'PACKAGES=('):
    assert t.index(needle) < wipe, needle
assert t.index('PACKAGES=(') < t.index('pacstrap -K')
PY
  before="$(sha256sum "$h" | cut -d' ' -f1)"
  python3 -I "$S/patch-mechos-offline-helper.py" "$h" >/dev/null
  [ "$before" = "$(sha256sum "$h" | cut -d' ' -f1)" ] || fail "helper patch is not idempotent ($variant)"
done
diff -q <(grep -v '^$' "$TMP/helper.raw") <(grep -v '^$' "$TMP/helper.hardened") >/dev/null \
  || fail "raw and hardened helpers diverge after patching"

# A drifted helper must fail loudly, never silently stay online.
sed 's/^pacstrap -K -C "\$PACCONF"/pacstrap -K -C "$DRIFTED"/' "$TMP/helper.pristine" > "$TMP/helper.drift"
grep -Fq 'DRIFTED' "$TMP/helper.drift" || fail "drift fixture was not created"
if python3 -I "$S/patch-mechos-offline-helper.py" "$TMP/helper.drift" >/dev/null 2>&1; then
  fail "patcher accepted a helper whose pacstrap anchor drifted"
fi

# --- 2. Builder wiring: lands after the current late stage, before mkarchiso, once.
cp "$S/build-mechos-archiso.sh" "$TMP/builder.sh"
python3 -I "$S/patch-mechos-current.py" "$TMP/builder.sh" >/dev/null
python3 -I "$S/patch-mechos-offline-installer.py" "$TMP/builder.sh"
python3 -I "$S/patch-mechos-offline-installer.py" "$TMP/builder.sh"
[ "$(grep -c '^# MECHOS_OFFLINE_INSTALLER_INTEGRATION$' "$TMP/builder.sh")" -eq 1 ] || fail "offline stage not inserted exactly once"
python3 -I - "$TMP/builder.sh" <<'PY' || fail "offline stage is not between the late integration and mkarchiso"
import sys
t = open(sys.argv[1]).read()
late = t.index('# MECHOS_CURRENT_INTEGRATION_LATE')
off = t.index('mechos-offline-installer-integration.sh final')
assert late < off < t.rindex('\nmkarchiso -v \\\n')
assert t.index('mechos-native-installer-integration.sh final') < off
PY
bash -n "$TMP/builder.sh" || fail "builder syntax broke after wiring"

# --- 3. Repository builder with stub pacman/repo-add.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/pacman" <<'STUBEOF'
#!/usr/bin/env bash
# Minimal pacman stand-in: -Sy no-op, -Sp prints a fixed closure, -Sw "downloads".
cache=""; mode=""; prev=""
for a in "$@"; do
  [ "$prev" = "--cachedir" ] && cache="$a"
  case "$a" in -Sy|-Sp|-Sw) mode="$a" ;; esac
  prev="$a"
done
rows=$'core\tbase\t3-1\tbase-3-1-any.pkg.tar.zst
core\tglibc\t2.40-1\tglibc-2.40-1-x86_64.pkg.tar.zst
extra\tqt6-base\t1:6.8-1\tqt6-base-1:6.8-1-x86_64.pkg.tar.zst
multilib\tlib32-mesa\t24.0-1\tlib32-mesa-24.0-1-x86_64.pkg.tar.zst'
case "$mode" in
  -Sy) exit 0 ;;
  -Sp) printf '%s\n' "$rows" ;;
  -Sw) printf '%s\n' "$rows" | while IFS=$'\t' read -r _ _ _ f; do
         echo "pkg:$f" > "$cache/$f"; echo sig > "$cache/$f.sig"; done ;;
esac
STUBEOF
cat > "$STUB/repo-add" <<'STUBEOF'
#!/usr/bin/env bash
# Mimics repo-add: writes <db>.tar.gz and a <name>.db symlink to it.
[ "$1" = "--quiet" ] && shift
db="$1"; shift
printf '%s\n' "$@" > "$db"
ln -sf "$db" "${db%.tar.gz}"
ln -sf "$db" "${db%.db.tar.gz}.files"
STUBEOF
chmod +x "$STUB/pacman" "$STUB/repo-add"
printf '%s\n' base qt6-base lib32-mesa glibc > "$TMP/pkgs.list"
printf '[options]\nArchitecture = auto\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n\n#[multilib]\n#Include = /etc/pacman.d/mirrorlist\n' > "$TMP/pacman.conf"
PATH="$STUB:$PATH" python3 -I "$S/mechos-offline-repo.py" --packages "$TMP/pkgs.list" \
  --out "$TMP/repo" --work "$TMP/work" --pacman-conf "$TMP/pacman.conf" >/dev/null || fail "repo builder failed against stub pacman"
grep -qx '\[multilib\]' "$TMP/work/pacman.conf" || fail "multilib was not enabled in the derived pacman.conf"
for r in core extra multilib; do
  d="$TMP/repo/$r/os/x86_64"
  [ -f "$d/$r.db" ] && [ ! -L "$d/$r.db" ] || fail "$r.db missing or still a symlink"
done
[ -s "$TMP/repo/extra/os/x86_64/qt6-base-1:6.8-1-x86_64.pkg.tar.zst" ] || fail "epoch-versioned package not placed"
[ -s "$TMP/repo/extra/os/x86_64/qt6-base-1:6.8-1-x86_64.pkg.tar.zst.sig" ] || fail "package signature not kept"
python3 -I - "$TMP/repo/manifest.json" <<'PY' || fail "manifest content wrong"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["package_count"] == 4 and m["repos"] == {"core": {"count": 2}, "extra": {"count": 1}, "multilib": {"count": 1}}
assert set(m["targets"]) == {"base", "qt6-base", "lib32-mesa", "glibc"} and m["total_bytes"] > 0
PY
# An empty package list must be rejected rather than yield an empty "offline" repo.
: > "$TMP/empty.list"
if PATH="$STUB:$PATH" python3 -I "$S/mechos-offline-repo.py" --packages "$TMP/empty.list" --out "$TMP/repo2" --work "$TMP/work2" --pacman-conf "$TMP/pacman.conf" >/dev/null 2>&1; then
  fail "repo builder accepted an empty package list"
fi

# --- 4. Toggle and host checks.
grep -Fq 'MECHOS_OFFLINE_REPO' "$BASE/build-iso.sh" || fail "build-iso.sh does not pass MECHOS_OFFLINE_REPO into the container"
grep -Fq 'MECHOS_OFFLINE_REPO' "$S/mechos-offline-installer-integration.sh" || fail "integration has no opt-out"
( MECHOS_OFFLINE_REPO=0 bash "$S/mechos-offline-installer-integration.sh" final >/dev/null ) || fail "opt-out should exit cleanly"

echo "Offline installer source validation passed."
