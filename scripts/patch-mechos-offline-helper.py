#!/usr/bin/env python3
# MECHOS_OFFLINE_HELPER_PATCH_V1
"""Make mechos-native-install-helper install from the bundled offline repo.

Usage: patch-mechos-offline-helper.py <path to mechos-native-install-helper>

Changes, all anchored on text the earlier installer stages generate (the patch
fails loudly if an anchor is missing, so a drifted helper can never silently
fall back to needing a network):

  1. The network/mirror preflight (hardening stage) is replaced by an offline
     repository preflight that runs before the disk is touched.
  2. The package list and NVIDIA detection move into that preflight so the
     driver packages ride along in the single pacstrap run.
  3. pacstrap reads the bundled core/extra/multilib file repositories.
  4. The NVIDIA `arch-chroot pacman -S` step (needs a network) is removed.
"""
import re
import sys
from pathlib import Path

MARKER = "# MECHOS_OFFLINE_INSTALL_V1"

PREFLIGHT_RE = re.compile(
    r"# MECHOS_NATIVE_INSTALL_PREFLIGHT_V1\n.*?\n(?=progress 4 \"Preparing selected disk\")",
    re.S,
)
PACKAGES_RE = re.compile(r"^PACKAGES=\(\n.*?\n\)\n", re.S | re.M)
BASE_RE = re.compile(
    r'progress 23 "Installing Arch base system internally"\n'
    r".*?"
    r'pacstrap -K -C "\$PACCONF" "\$MNT" "\$\{PACKAGES\[@\]\}"\n'
    r'rm -f "\$PACCONF"\n',
    re.S,
)
NVIDIA_CHROOT = (
    '  arch-chroot "$MNT" pacman -S --needed --noconfirm '
    "nvidia-open nvidia-utils lib32-nvidia-utils nvidia-prime\n"
)
DISK_ANCHOR = 'progress 4 "Preparing selected disk"\n'

PREFLIGHT = r'''# MECHOS_OFFLINE_INSTALL_V1
# The Live image carries every package the installed system needs in
# /usr/share/mechos/offline-repo: core/extra/multilib file repositories built at
# ISO-build time from the full dependency closure of the list below. Nothing in
# this installer needs a network connection. All checks run before wipefs/sfdisk
# so a damaged image can never leave a half-erased disk behind.
progress 1 "Checking bundled offline package repository"
OFFLINE_REPO=/usr/share/mechos/offline-repo
OFFLINE_DB=/tmp/mechos-offline-db
OFFLINE_CONF=/tmp/mechos-offline-pacman.conf
OFFLINE_LOG=/tmp/mechos-offline-preflight.log
OFFLINE_URLS=/tmp/mechos-offline-urls.txt

@@PACKAGES@@
# NVIDIA drivers are installed by the same pacstrap run; a later chroot pacman
# call would need a network. The offline repo always carries these packages.
GPU_TEXT="$(lspci -nn 2>/dev/null | grep -Ei 'VGA|3D|Display' || true)"
if printf '%s\n' "$GPU_TEXT" | grep -qi NVIDIA; then
  PACKAGES+=(nvidia-open nvidia-utils lib32-nvidia-utils)
fi

command -v pacman >/dev/null 2>&1 || fail "pacman is missing from the Live image. No disk changes were made."
[ -s "$OFFLINE_REPO/manifest.json" ] \
  || fail "The bundled offline package repository is missing from this Live image. No disk changes were made."
for repo in core extra multilib; do
  [ -s "$OFFLINE_REPO/$repo/os/x86_64/$repo.db" ] \
    || fail "The bundled '$repo' package database is missing. No disk changes were made."
done

# SigLevel Never is deliberate: every package was signature-verified by pacman
# when the ISO was built, and the ISO checksum covers them afterwards. Checking
# again here would fail on machines with an unset or old hardware clock
# ("signature created in the future"), which is common for offline installs.
cat > "$OFFLINE_CONF" <<OFFLINE_CONF_EOF
[options]
Architecture = x86_64
CheckSpace
SigLevel = Never
LocalFileSigLevel = Never

[core]
Server = file://$OFFLINE_REPO/core/os/x86_64

[extra]
Server = file://$OFFLINE_REPO/extra/os/x86_64

[multilib]
Server = file://$OFFLINE_REPO/multilib/os/x86_64
OFFLINE_CONF_EOF

# Dry run: refresh the bundled databases and resolve the whole package list
# against them, then confirm every package file exists, before any disk change.
rm -rf "$OFFLINE_DB"
mkdir -p "$OFFLINE_DB/local" "$OFFLINE_DB/sync"
: > "$OFFLINE_LOG"
pacman --config "$OFFLINE_CONF" --dbpath "$OFFLINE_DB" --noconfirm -Sy >>"$OFFLINE_LOG" 2>&1 \
  || fail "The bundled package databases could not be read. No disk changes were made. See $OFFLINE_LOG."
pacman --config "$OFFLINE_CONF" --dbpath "$OFFLINE_DB" --noconfirm -Sp --print-format '%r %f' \
  "${PACKAGES[@]}" >"$OFFLINE_URLS" 2>>"$OFFLINE_LOG" \
  || fail "The bundled repository cannot satisfy the MechOS package set. No disk changes were made. See $OFFLINE_LOG."
# Check by repo + filename rather than by the URL pacman prints, so the result
# does not depend on how libalpm reports file:// repository locations.
resolved=0
while read -r repo_name pkg_file; do
  [ -n "$pkg_file" ] || continue
  [ -s "$OFFLINE_REPO/$repo_name/os/x86_64/$pkg_file" ] \
    || fail "Bundled package file is missing or empty: $pkg_file. No disk changes were made."
  resolved=$((resolved + 1))
done <"$OFFLINE_URLS"
[ "$resolved" -gt 0 ] || fail "The bundled repository resolved no packages. No disk changes were made. See $OFFLINE_LOG."
rm -f "$OFFLINE_URLS"

'''

BASE_BLOCK = r'''progress 23 "Installing Arch base system from the bundled offline repository"
pacstrap -K -C "$OFFLINE_CONF" "$MNT" "${PACKAGES[@]}"
rm -rf "$OFFLINE_CONF" "$OFFLINE_DB"
'''


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: patch-mechos-offline-helper.py <mechos-native-install-helper>")
    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print("[MechOS Offline Helper] already patched")
        return

    pk = PACKAGES_RE.search(text)
    if not pk:
        sys.exit("[MechOS Offline Helper] PACKAGES array anchor not found")
    packages_block = pk.group(0)

    if not BASE_RE.search(text):
        sys.exit("[MechOS Offline Helper] pacstrap/base-system anchor not found")
    if NVIDIA_CHROOT not in text:
        sys.exit("[MechOS Offline Helper] NVIDIA chroot install anchor not found")
    if DISK_ANCHOR not in text:
        sys.exit("[MechOS Offline Helper] destructive-work anchor not found")

    preflight = PREFLIGHT.replace("@@PACKAGES@@\n", packages_block)

    # 1. Replace the online preflight; if the hardening stage has not run, put
    #    the offline preflight in the same place (right before the wipe).
    if PREFLIGHT_RE.search(text):
        text = PREFLIGHT_RE.sub(lambda _m: preflight, text, count=1)
    else:
        text = text.replace(DISK_ANCHOR, preflight + DISK_ANCHOR, 1)

    # 2/3. pacstrap from the bundled repo. The PACKAGES array now lives in the
    #      preflight, so this block (which held the original) is replaced whole.
    text, n = BASE_RE.subn(lambda _m: BASE_BLOCK, text, count=1)
    if n != 1:
        sys.exit("[MechOS Offline Helper] could not rewrite the pacstrap block")

    # 4. NVIDIA packages are already installed by pacstrap.
    text = text.replace(NVIDIA_CHROOT, "", 1)

    # Nothing online may remain on the install path.
    for needle in ("pacman -Sy --noconfirm >/tmp/mechos-installer-pacman-preflight.log",
                   'pacstrap -K -C "$PACCONF"', "arch-chroot \"$MNT\" pacman -S"):
        if needle in text:
            sys.exit(f"[MechOS Offline Helper] online step survived patching: {needle}")
    if text.count("PACKAGES=(\n") != 1:
        sys.exit("[MechOS Offline Helper] expected exactly one PACKAGES array after patching")

    path.write_text(text, encoding="utf-8")
    print("[MechOS Offline Helper] helper now installs from the bundled offline repository")


if __name__ == "__main__":
    main()
