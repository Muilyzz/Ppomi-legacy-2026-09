#!/usr/bin/env python3
"""Copy only recursively required, non-system runtime libraries into jniLibs."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

readelf, destination, *locations = sys.argv[1:]
destination = Path(destination)
locations = [Path(item) for item in locations]
system = {"libc.so", "libm.so", "libdl.so", "liblog.so", "libandroid.so", "libz.so"}
pending = [destination / "libppomi_accounting.so", destination / "libppomi_accounting_core.so"]
seen = set()
while pending:
    library = pending.pop()
    if library.name in seen:
        continue
    seen.add(library.name)
    metadata = subprocess.check_output([readelf, "-d", str(library)], text=True)
    for name in re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", metadata):
        if name in system or name in seen:
            continue
        output = destination / name
        source = next((directory / name for directory in locations if (directory / name).is_file()), None)
        if source:
            shutil.copyfile(source, output)
        elif not output.is_file():
            raise RuntimeError("Missing runtime dependency: " + name)
        pending.append(output)
# Avoid retaining libraries from an older SDK/configuration in the APK.
for old in destination.glob("*.so"):
    if old.name not in seen:
        old.unlink()
manifest = {name: hashlib.sha256((destination / name).read_bytes()).hexdigest() for name in sorted(seen)}
(destination.parent.parent / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Packaged %d native libraries (%0.1f MiB)" % (len(seen), sum((destination / name).stat().st_size for name in seen) / 2**20))
