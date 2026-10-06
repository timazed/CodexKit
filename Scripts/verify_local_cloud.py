#!/usr/bin/env python3
"""Opt-in Swift/Node integration check. Ordinary Swift builds do not require Node."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import subprocess
import sys
import time
import uuid
import verify_ios_simulator as ios

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "packages/codexkit"
REPORTS = ROOT / ".build/local-cloud"


def run_ios(app, base_url, reports):
    with (reports / "simulator.log").open("w") as log:
        runtime, device = ios.select_simulator(ios.discover_runtimes(log=log))
        simulator = ios.run(["xcrun", "simctl", "create", f"CodexKit local cloud {uuid.uuid4()}",
                             device["identifier"], runtime["identifier"]])
        try:
            ios.boot_simulator(simulator, log=log)
            ios.run(["xcrun", "simctl", "install", simulator, str(app)], log=log, timeout=180)
            with (app / "Info.plist").open("rb") as source:
                bundle = plistlib.load(source)["CFBundleIdentifier"]
            container = ios.resolve_app_container(simulator, bundle, log=log)
            report = container / "Documents/LocalCloudVerification.json"
            ios.run(["xcrun", "simctl", "launch", simulator, bundle, "--verify-local-cloud",
                     "--local-cloud-url", base_url, "--verification-result", str(report)], log=log)
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if report.exists():
                    return json.loads(report.read_text())
                time.sleep(0.2)
            raise RuntimeError("Simulator did not produce its local cloud report within 120 seconds.")
        finally:
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], stdout=log, stderr=log, timeout=60)
            subprocess.run(["xcrun", "simctl", "delete", simulator], stdout=log, stderr=log, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Use the already-built signed demo and cloud library.")
    parser.add_argument("--platform", choices=["macos", "ios"], default="macos")
    args = parser.parse_args()
    node = shutil.which("node")
    npm = shutil.which("npm")
    if not node or not npm:
        raise RuntimeError("Install Node 22 or 24 for this optional integration check.")
    reports = REPORTS / args.platform
    reports.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        subprocess.run([npm, "run", "build"], cwd=PACKAGE, check=True, timeout=60)
        verifier = ["Scripts/verify_macos_demo.py"] if args.platform == "macos" else ["Scripts/verify_ios_simulator.py", "--build-only"]
        subprocess.run([sys.executable, *verifier], cwd=ROOT, check=True, timeout=1900)
    app = ROOT / (".build/macos-demo/Build/Products/Debug/CodexKitMacDemo.app" if args.platform == "macos"
                  else ".build/simulator-verification/Build/Products/Debug-iphonesimulator/CodexKitIOSDemo.app")
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    report_path = reports / "result.json"
    report_path.unlink(missing_ok=True)
    with (reports / "api.log").open("w") as api_log:
        api = subprocess.Popen([node, "examples/local-api/main.cjs", "--port", "0"],
                               cwd=PACKAGE, stdout=subprocess.PIPE, stderr=api_log, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(api.stdout, selectors.EVENT_READ)
                if not selector.select(timeout=10):
                    raise RuntimeError("Local API did not start within 10 seconds.")
                line = api.stdout.readline()
            api_log.write(line)
            match = re.fullmatch(r"CodexKit local API: (http://127\.0\.0\.1:\d+) \(fixture\)\n", line)
            if not match:
                raise RuntimeError(f"Local fixture API failed to start; see {reports / 'api.log'}.")
            if args.platform == "ios":
                report = run_ios(app, match[1], reports)
                report_path.write_text(json.dumps(report, indent=2) + "\n")
                returncode = 0
            else:
                with (reports / "app.log").open("w") as app_log:
                    result = subprocess.run([str(app / "Contents/MacOS/CodexKitMacDemo"),
                        "--verify-local-cloud", "--local-cloud-url", match[1],
                        "--verification-result", str(report_path)], cwd=ROOT,
                        stdout=app_log, stderr=subprocess.STDOUT, timeout=120)
                returncode = result.returncode
                report = json.loads(report_path.read_text()) if report_path.exists() else {}
            if returncode or report.get("passed") is not True:
                raise RuntimeError(f"Local cloud verification failed: {report.get('error', 'missing report')}")
            for check in report["checks"]:
                print(f"PASS: {check}")
            print(f"Report: {report_path}")
        finally:
            api.terminate()
            try:
                api.wait(timeout=5)
            except subprocess.TimeoutExpired:
                api.kill()
                api.wait(timeout=5)
            api.stdout.close()


if __name__ == "__main__":
    main()
