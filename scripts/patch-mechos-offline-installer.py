#!/usr/bin/env python3
"""Wire the offline installer stage into the ISO builder.

Run after every other patch-mechos-*.py so the stage lands last, immediately
before mkarchiso, with nothing after it able to regenerate the installer helper.
"""
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: patch-mechos-offline-installer.py <build-script>')

path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
marker = '# MECHOS_OFFLINE_INSTALLER_INTEGRATION'
if marker in text:
    raise SystemExit(0)

anchor = '\nmkarchiso -v \\\n'
pos = text.rfind(anchor)
if pos < 0:
    raise SystemExit('[MechOS Offline Installer] final mkarchiso insertion point not found')
late = text.rfind('# MECHOS_CURRENT_INTEGRATION_LATE', 0, pos)
if late < 0:
    raise SystemExit('[MechOS Offline Installer] current late integration stage not found before mkarchiso')
if 'mechos-native-installer-integration.sh final' not in text:
    raise SystemExit('[MechOS Offline Installer] native installer stage is not wired into the builder; run patch-mechos-current.py first')

insert = '''

# MECHOS_OFFLINE_INSTALLER_INTEGRATION
# ABSOLUTE-LAST INSTALLER AUTHORITY. Bundle the full offline package repository
# into the Live image and point the native Clean Install at it, so installation
# needs no network. Set MECHOS_OFFLINE_REPO=0 to skip (online-install test build).
bash /workspace/scripts/mechos-offline-installer-integration.sh final
'''

text = text[:pos] + insert + text[pos:]
path.write_text(text, encoding='utf-8')
