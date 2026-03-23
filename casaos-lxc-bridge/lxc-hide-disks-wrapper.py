#!/usr/bin/env python3
"""lsblk wrapper: filtert Host-Blockgeraete (sd*, nvme*, hd*, vd*) aus Output.
Verhindert dass casaos-local-storage physische Proxmox-Laufwerke erkennt."""
import subprocess
import json
import sys
import re

HIDDEN = ("sd", "nvme", "hd", "vd")
TREE_RE = re.compile(r"^[|`\- ]*(\S+)")

result = subprocess.run(
    ["/usr/bin/lsblk.real"] + sys.argv[1:],
    capture_output=True, text=True
)

if "-J" in sys.argv or "--json" in sys.argv:
    try:
        data = json.loads(result.stdout)
        data["blockdevices"] = [
            d for d in data.get("blockdevices", [])
            if not any(d.get("name", "").startswith(p) for p in HIDDEN)
        ]
        print(json.dumps(data))
    except Exception:
        print(result.stdout, end="")
else:
    for line in result.stdout.splitlines():
        m = TREE_RE.match(line)
        if m and any(m.group(1).startswith(p) for p in HIDDEN):
            continue
        print(line)

if result.stderr:
    print(result.stderr, end="", file=sys.stderr)
sys.exit(result.returncode)
