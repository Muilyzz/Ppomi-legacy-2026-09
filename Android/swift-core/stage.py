#!/usr/bin/env python3
"""Stage canonical Swift files without a maintained Android fork; record byte hashes."""
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCES = [
    "Ppomi/Sources/Ppomi/Accounting/AccountingModel.swift",
    "Ppomi/Sources/Ppomi/Accounting/AccountingEngine.swift",
    "Ppomi/Sources/Ppomi/Records/RecordScope.swift",
    # AccountingEngine and the archive bridge reuse canonical models and timestamp validation.
    "Ppomi/Sources/Ppomi/Records/LifeModel.swift",
    "Ppomi/Sources/Ppomi/Records/LifeJSON.swift",
]


def write_if_changed(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


def stage():
    destination = HERE / "build/Sources/SharedAccountingCore"
    hashes = {}
    for source in SOURCES:
        data = (ROOT / source).read_bytes()
        hashes[source] = hashlib.sha256(data).hexdigest()
        output = destination / Path(source).name
        write_if_changed(output, data)
        assert output.read_bytes() == data
    write_if_changed(destination / "AccountingBridge.swift", (HERE / "Sources/AccountingBridge.swift").read_bytes())
    identity = "enum CanonicalSourceIdentity { static let hashes: [String: String] = [\n"
    identity += ",\n".join("    " + json.dumps(key) + ": " + json.dumps(value) for key, value in sorted(hashes.items()))
    identity += "\n] }\n"
    write_if_changed(destination / "CanonicalSourceIdentity.swift", identity.encode())
    example = ROOT / "Ppomi/Sources/Ppomi/AccountingData/example.json"
    write_if_changed(HERE / "build/assets/accounting-example.json", example.read_bytes())
    manifest = {"sources": hashes, "example": {"source": str(example.relative_to(ROOT)),
                "sha256": hashlib.sha256(example.read_bytes()).hexdigest(), "provenance": "synthetic"}}
    write_if_changed(HERE / "build/source-manifest.json", (json.dumps(manifest, indent=2) + "\n").encode())
    return manifest


if __name__ == "__main__":
    stage()
