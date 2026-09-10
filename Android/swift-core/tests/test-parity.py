#!/usr/bin/env python3
"""Assert golden behavior and JSON equality on Mac, Android Swift, and Android JNI.

All input is synthetic. The device probe uses a private /data/local/tmp directory;
it does not launch UI, change ADB forwarding, install APKs, or access user books.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[1]
BUILD = HERE / "build"


def run(args, **kwargs):
    return subprocess.run([str(item) for item in args], check=True, capture_output=True, timeout=120, **kwargs).stdout


def simple_archive(amount=100):
    return {"formatVersion": 1, "books": [{"id": "book", "name": "합성 검증 🧾", "ownerID": "owner:test",
             "kind": "financial", "scope": {"kind": "personal", "ownerID": "owner:test"},
             "unit": {"id": "KRW", "name": "원", "symbol": "원", "dimension": "currency", "scale": 0}}],
            "accounts": [{"id": "expense", "bookID": "book", "name": "비용 🧾", "kind": "expense"},
                         {"id": "bank", "bookID": "book", "name": "예금", "kind": "asset"}],
            "entries": [{"id": "entry", "eventID": "event", "bookID": "book",
                         "occurredAt": "2026-09-08T09:00:00+09:00", "recordedAt": "2026-09-08T09:00:01+09:00",
                         "memo": "한글과 이모지 🧾", "source": "synthetic-test", "sourceRecordID": "source:one",
                         "layer": "recorded", "postings": [{"accountID": "expense", "side": "debit", "amount": amount},
                                                               {"accountID": "bank", "side": "credit", "amount": amount}]}]}


def cases():
    example = json.loads((BUILD / "assets/accounting-example.json").read_text())
    yield "canonical-money-time-business", example, True
    yield "unicode-and-integer", simple_archive(), True
    yield "above-double-integer-precision", simple_archive(9_007_199_254_740_993), True
    legacy = simple_archive()
    del legacy["books"][0]["scope"]
    yield "legacy-scope-stays-unclassified", legacy, True
    withdrawn = copy.deepcopy(example)
    previous = next(item for item in withdrawn["entries"] if item["id"] == "example-money-estimate")
    successor = copy.deepcopy(previous)
    successor.update(id="withdrawal", postings=[], recordedAt="2026-09-09T00:00:00Z")
    successor["assessment"].update(replacesEntryID=previous["id"], rationale="합성 테스트: 이전 추정 철회")
    withdrawn["entries"].append(successor)
    yield "adjustment-withdrawal-preserves-source", withdrawn, True
    mismatch = simple_archive()
    mismatch["books"][0]["scope"]["ownerID"] = "owner:other"
    yield "scope-owner-mismatch", mismatch, False
    cross = simple_archive()
    other = copy.deepcopy(cross["books"][0]); other["id"] = "other-book"
    cross["books"].append(other)
    cross["accounts"][0]["bookID"] = "other-book"
    yield "cross-book-posting", cross, False
    unbalanced = simple_archive(); unbalanced["entries"][0]["postings"][0]["amount"] = 101
    yield "unbalanced-journal", unbalanced, False
    fractional = simple_archive(); fractional["entries"][0]["postings"][0]["amount"] = 0.1
    yield "fractional-minor-unit", fractional, False
    overflow = simple_archive(9_223_372_036_854_775_807)
    second = copy.deepcopy(overflow["entries"][0]); second.update(id="second", sourceRecordID="source:two")
    overflow["entries"].append(second)
    yield "balance-overflow", overflow, False
    duplicate = simple_archive(); duplicate["accounts"].append(copy.deepcopy(duplicate["accounts"][0]))
    yield "duplicate-stable-id", duplicate, False
    timestamp = simple_archive(); timestamp["entries"][0]["occurredAt"] = "2026-02-30T09:00:00+09:00"
    yield "invalid-calendar-date", timestamp, False
    business = simple_archive()
    business["books"][0]["scope"] = {"kind": "business", "ownerID": "owner:test", "businessID": "business:test"}
    other = copy.deepcopy(business["books"][0]); other.update(id="other", ownerID="owner:other")
    other["scope"]["ownerID"] = "owner:other"
    business["books"].append(other)
    yield "business-id-owner-collision", business, False
    time_money = simple_archive(); time_money["books"][0]["unit"]["dimension"] = "time"
    yield "financial-time-unit-rejected", time_money, False


def golden(name, result):
    books = {item["book"]["id"]: item for item in result.get("books", [])}
    if name == "canonical-money-time-business":
        assert len(books) == 3
        money, time = books["example-money"], books["example-time"]
        assert money["recordedBalances"]["money-learning"] == 100000
        assert money["adjustedBalances"]["money-learning"] == 40000
        assert money["adjustedBalances"]["money-skill"] == 60000
        assert time["recordedBalances"]["time-learning-expense"] == 120
        assert time["adjustedBalances"]["time-learning-expense"] == 48
        assert time["adjustedBalances"]["time-learning-asset"] == 72
        assert books["example-business-money"]["scope"]["kind"] == "business"
        assert books["example-business-money"]["recordedBalances"] == {}
    elif name == "above-double-integer-precision":
        assert books["book"]["recordedBalances"]["expense"] == 9_007_199_254_740_993
        assert books["book"]["recordedBalances"]["bank"] == -9_007_199_254_740_993
    elif name == "legacy-scope-stays-unclassified":
        assert "scope" not in books["book"]["book"]
        assert books["book"]["scope"] == {"kind": "unclassified", "ownerID": "owner:test"}
    elif name == "unicode-and-integer":
        assert books["book"]["recordedEntries"][0]["memo"] == "한글과 이모지 🧾"
    elif name == "adjustment-withdrawal-preserves-source":
        money = books["example-money"]
        assert money["recordedBalances"] == money["adjustedBalances"]
        assert "example-money-estimate" not in [entry["id"] for entry in money["adjustedEntries"]]
        assert "withdrawal" in [entry["id"] for entry in money["adjustedEntries"]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="An explicit emulator-NNNN serial")
    parser.add_argument("--skip-build", action="store_true")
    options = parser.parse_args()
    if not re.fullmatch(r"emulator-[0-9]+", options.serial):
        raise RuntimeError("Only explicit Android emulator serials are supported.")
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or Path.home() / "Library/Android/sdk")
    adb = [sdk / "platform-tools/adb", "-s", options.serial]
    assert run(adb + ["shell", "getprop", "ro.kernel.qemu"]).strip() == b"1", "Not an Android emulator"
    assert run(adb + ["shell", "getprop", "ro.product.cpu.abi"]).strip() == b"arm64-v8a", "Expected ARM64 emulator"
    if not options.skip_build:
        print(run([HERE / "build.sh", "host"]).decode(), end="")
        print(run([HERE / "build.sh", "android"]).decode(), end="")
    java = Path(os.environ.get("JAVA_HOME") or "/Applications/Android Studio.app/Contents/jbr/Contents/Home")
    probe = BUILD / "probe"
    (probe / "classes").mkdir(parents=True, exist_ok=True)
    (probe / "dex").mkdir(exist_ok=True)
    run([java / "bin/javac", "--release", "8", "-Xlint:-options", "-d", probe / "classes",
         ROOT / "Android/app/src/main/java/com/ppomi/androidbridge/SharedAccounting.java", HERE / "tests/JniProbe.java"])
    run([java / "bin/jar", "cf", probe / "probe.jar", "-C", probe / "classes", "."])
    run([sdk / "build-tools/34.0.0/d8", "--min-api", "28", "--lib", sdk / "platforms/android-35/android.jar",
         "--output", probe / "dex", probe / "probe.jar"], env={**os.environ, "JAVA_HOME": str(java)})
    remote = "/data/local/tmp/ppomi-shared-core"
    run(adb + ["shell", "mkdir", "-p", remote])
    run(adb + ["push", str(BUILD / "jniLibs/arm64-v8a") + "/.", remote + "/"])
    run(adb + ["push", BUILD / "android/aarch64-unknown-linux-android28/release/accounting-core", probe / "dex/classes.dex", remote + "/"])
    run(adb + ["shell", "chmod", "755", remote + "/accounting-core"])
    fixture = BUILD / "parity-input.json"
    outcomes = []
    for name, archive, expected in cases():
        fixture.write_text(json.dumps(archive, ensure_ascii=False))
        host = json.loads(run([BUILD / "host/release/accounting-core", fixture]))
        assert host["ok"] is expected, (name, host)
        golden(name, host)
        run(adb + ["push", fixture, remote + "/input.json"])
        android = json.loads(run(adb + ["exec-out", "env", "LD_LIBRARY_PATH=" + remote,
                                       remote + "/accounting-core", remote + "/input.json"]))
        jni = json.loads(run(adb + ["exec-out", "env", "LD_LIBRARY_PATH=" + remote, "CLASSPATH=" + remote + "/classes.dex",
                                   "app_process", "-Djava.library.path=" + remote, "/system/bin",
                                   "com.ppomi.androidbridge.JniProbe", remote + "/input.json"]))
        assert android == host, (name, "Android Swift differs from Mac")
        assert jni == host, (name, "Android JNI differs from Mac")
        outcomes.append({"case": name, "passed": True, "expectedValid": expected})
        print("PASS", name)
    manifest = json.loads((BUILD / "source-manifest.json").read_text())
    for source, digest in manifest["sources"].items():
        assert hashlib.sha256((ROOT / source).read_bytes()).hexdigest() == digest, "Canonical source changed during test"
    result = {"serial": options.serial, "abi": "arm64-v8a", "passed": len(outcomes), "cases": outcomes,
              "paths": ["Mac Swift", "Android Swift executable", "Android Java → JNI → Swift shared library"],
              "sourceHashes": manifest["sources"]}
    (BUILD / "parity-result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": len(outcomes), "result": str(BUILD / "parity-result.json")}))


if __name__ == "__main__":
    main()
