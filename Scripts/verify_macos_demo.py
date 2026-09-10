#!/usr/bin/env python3
"""Build the signed macOS demo and run smoke or full offline app verification."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

from verification_timing import Timings

ROOT = Path(__file__).resolve().parents[1]


def validate_report(result, run_id, mode, phase):
    if (result.get("runID") != run_id or result.get("mode") != mode or result.get("phase") != phase
            or result.get("passed") is not True or not result.get("checks")):
        raise RuntimeError(f"macOS {phase} verification failed or returned a stale report: {result.get('error', 'invalid report')}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--mode", choices=("smoke", "full"), default="smoke")
    args = parser.parse_args()
    derived = ROOT / ".build/macos-demo"
    derived.mkdir(parents=True, exist_ok=True)
    timings = Timings(derived / "timings.json")
    if not args.skip_build:
        log = derived / "build.log"
        with timings.measure("build"), log.open("w") as output:
            result = subprocess.run([
                "xcodebuild", "-project", str(ROOT / "DemoApp/CodexKitDemo.xcodeproj"),
                "-scheme", "CodexKitMacDemo", "-configuration", "Debug",
                "-destination", "platform=macOS", "-derivedDataPath", str(derived),
                "-onlyUsePackageVersionsFromResolvedFile", "build",
            ], cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, timeout=900)
        if result.returncode:
            raise RuntimeError(f"macOS demo build failed; see {log}")
    app = derived / "Build/Products/Debug/CodexKitMacDemo.app"
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    run_id = str(uuid.uuid4())
    environment = dict(os.environ, CODEXKIT_VERIFICATION_RUN_ID=run_id)
    with tempfile.TemporaryDirectory(prefix="codexkit-demo-verification-") as temporary:
        result_path = Path(temporary) / "result.json"
        command = [str(app / "Contents/MacOS/CodexKitMacDemo"), "--verify-local-only",
                   "--verification-result", str(result_path)]
        if args.mode == "smoke":
            command.append("--verify-smoke")
        for phase in ("initial", "reopen"):
            result_path.unlink(missing_ok=True)
            extra = ["--verify-recovery-reopen"] if phase == "reopen" else []
            with timings.measure(phase):
                subprocess.run(command + extra, check=True, timeout=45, env=environment)
            if not result_path.exists():
                raise RuntimeError(f"The macOS demo exited without its {phase} report")
            result = json.loads(result_path.read_text())
            report = "recovery-reopen-result.json" if phase == "reopen" else "verification-result.json"
            (derived / report).write_text(json.dumps(result, indent=2) + "\n")
            validate_report(result, run_id, args.mode, phase)
            for check in result["checks"]:
                print(f"PASS: {check}")
        print(f"macOS demo {args.mode} verification passed, including a second app process.")
        print(f"App: {app}")


if __name__ == "__main__":
    main()
