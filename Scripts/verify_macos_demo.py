#!/usr/bin/env python3
"""Build the native macOS demo and run its isolated, offline integration checks."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    derived = ROOT / ".build/macos-demo"
    derived.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        log = derived / "build.log"
        with log.open("w") as output:
            result = subprocess.run([
                "xcodebuild", "-project", str(ROOT / "DemoApp/CodexKitDemo.xcodeproj"),
                "-scheme", "CodexKitMacDemo", "-configuration", "Debug",
                "-destination", "platform=macOS", "-derivedDataPath", str(derived),
                "build",
            ], cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f"macOS demo build failed; see {log}")
    app = derived / "Build/Products/Debug/CodexKitMacDemo.app"
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    with tempfile.TemporaryDirectory(prefix="codexkit-demo-verification-") as temporary:
        result_path = Path(temporary) / "result.json"
        # Direct execution creates a separate app process and avoids deferred background launch.
        subprocess.run([str(app / "Contents/MacOS/CodexKitMacDemo"), "--verify-local-only",
                        "--verification-result", str(result_path)], check=True, timeout=45)
        if not result_path.exists():
            raise RuntimeError("The macOS demo exited without a verification result")
        result = json.loads(result_path.read_text())
        (derived / "verification-result.json").write_text(json.dumps(result, indent=2) + "\n")
        if not result.get("passed"):
            raise RuntimeError(f"macOS demo verification failed: {result.get('error', 'unknown failure')}")
        for check in result["checks"]:
            print(f"PASS: {check}")
        subprocess.run([str(app / "Contents/MacOS/CodexKitMacDemo"), "--verify-local-only",
                        "--verify-recovery-reopen", "--verification-result", str(result_path)], check=True, timeout=45)
        reopened = json.loads(result_path.read_text())
        if not reopened.get("passed"):
            raise RuntimeError(f"macOS cold recovery failed: {reopened.get('error', 'unknown failure')}")
        (derived / "recovery-reopen-result.json").write_text(json.dumps(reopened, indent=2) + "\n")
        for check in reopened["checks"]:
            print(f"PASS: {check}")
        print(f"macOS demo verification passed ({len(result['checks'])} checks).")
        print(f"App: {app}")


if __name__ == "__main__":
    main()
