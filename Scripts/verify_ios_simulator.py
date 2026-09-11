#!/usr/bin/env python3
"""Build, run, and validate the local SDK verifier in a disposable iPhone simulator."""
import argparse
from collections import deque
import json
import os
import platform
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time
import uuid
from verification_timing import Timings
from verification_modes import VerificationMode

ROOT = Path(__file__).resolve().parents[1]


def run(args, *, log=None, timeout=60, env=None):
    result = subprocess.run(args, cwd=ROOT, env=env, timeout=timeout, text=True,
                            stdout=log or subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        details = result.stdout or ""
        if log:
            log.flush()
            with Path(log.name).open(errors="replace") as source:
                details = "".join(deque(source, maxlen=60))[-12000:]
        raise RuntimeError(f"{args[0]} {args[1]} failed ({result.returncode}). "
                           + (details or "See verification logs."))
    return (result.stdout or "").strip()


def select_simulator(runtimes, requested=None):
    candidates = [r for r in runtimes if r.get("isAvailable") and ".iOS-" in r["identifier"]
                  and int(r["version"].split(".")[0]) >= 17]
    if requested:
        candidates = [r for r in candidates if requested in (r["identifier"], r["version"], r["name"])]
    for runtime in sorted(candidates, key=lambda r: tuple(map(int, r["version"].split("."))), reverse=True):
        phones = [d for d in runtime.get("supportedDeviceTypes", []) if d.get("productFamily") == "iPhone"]
        if phones:
            return runtime, phones[0]
    raise RuntimeError("No compatible installed iPhone simulator runtime was found.")


def discover_runtimes(*, log, timeout=120):
    """Cold hosted runners can time out starting CoreSimulator; retry only this read."""
    command = ["xcrun", "simctl", "list", "runtimes", "--json"]
    deadline = time.monotonic() + timeout
    attempts = 0
    while (remaining := deadline - time.monotonic()) > 0:
        attempts += 1
        print(f"Runtime discovery attempt {attempts}", file=log, flush=True)
        try:
            result = run(command, timeout=min(60, remaining))
        except subprocess.TimeoutExpired as error:
            print(str(error), file=log, flush=True)
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(2, remaining))
            continue
        # Malformed data and nonzero command exits must not be hidden by retries.
        return json.loads(result)["runtimes"]
    raise RuntimeError(f"Simulator runtime discovery timed out after {timeout}s ({attempts} attempts)")


def validate_report(report, run_id, mode=VerificationMode.SMOKE):
    if report.get("runID") != run_id or not report.get("finishedAt") or report.get("mode") != mode:
        raise RuntimeError("Simulator verification returned a stale or incomplete report.")
    for key in ("sqlite", "realm", "localAdapters", "recovery"):
        if report.get(key) != "passed":
            raise RuntimeError(f"Simulator verification {key}: {report.get(key, 'missing')}")
    if report.get("liveProvider") != "skipped: local_only":
        raise RuntimeError("CI verification must explicitly skip live-account access.")


def resolve_app_container(simulator, bundle_id, *, log, timeout=180):
    """Retry a timed-out read without reinstalling or relaunching the verifier."""
    command = ["xcrun", "simctl", "get_app_container", simulator, bundle_id, "data"]
    deadline = time.monotonic() + timeout
    attempts = 0
    last_error = None
    while (remaining := deadline - time.monotonic()) > 0:
        attempts += 1
        attempt_timeout = min(60, remaining)
        print(f"Attempt {attempts}: data container for {bundle_id} on {simulator}; "
              f"timeout {attempt_timeout:.1f}s.", file=log, flush=True)
        try:
            value = run(command, timeout=attempt_timeout)
        except subprocess.TimeoutExpired as error:
            last_error = error
            print(str(error), file=log, flush=True)
            remaining = deadline - time.monotonic()
            if remaining > 0:
                print("Simulator data-container lookup timed out; retrying the lookup.", flush=True)
                time.sleep(min(2, remaining))
            continue
        except (RuntimeError, OSError) as error:
            print(str(error), file=log, flush=True)
            raise
        container = Path(value)
        if not value or not container.is_absolute() or not container.is_dir():
            error = f"Simulator returned an invalid data-container path: {value!r}"
            print(error, file=log, flush=True)
            raise RuntimeError(error)
        print(f"Resolved data container: {container}", file=log, flush=True)
        return container
    raise RuntimeError(f"Could not locate the data container for {bundle_id} on {simulator} "
                       f"within {timeout} seconds ({attempts} attempts). Last error: {last_error}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / ".build/verification")
    parser.add_argument("--derived-data", type=Path, default=ROOT / ".build/simulator-verification")
    parser.add_argument("--runtime", help="Installed iOS version or runtime identifier; defaults to newest available.")
    parser.add_argument("--report-timeout", type=int, default=180)
    parser.add_argument("--mode", type=VerificationMode, choices=list(VerificationMode), default=VerificationMode.SMOKE)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--build-only", action="store_true", help="Build a signed universal simulator app without launching it.")
    mode.add_argument("--app", type=Path, help="Install and verify an already-built signed simulator app.")
    options = parser.parse_args()
    if options.report_timeout <= 0:
        parser.error("--report-timeout must be positive")
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    timings = Timings(output / "timings.json")
    for name in ("CodexKitVerification.json", "run.json", "failure.txt", "build.log", "boot.log", "container.log",
                 "app-stdout.log", "app-stderr.log"):
        (output / name).unlink(missing_ok=True)
    derived = options.derived_data.resolve()
    run_id = str(uuid.uuid4())
    simulator = None

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        if not options.build_only:
            with timings.measure("runtime_discovery"), (output / "runtime-discovery.log").open("w") as log:
                runtimes = discover_runtimes(log=log)
            runtime, device = select_simulator(runtimes, options.runtime)
            print(f"Verifying on {runtime['name']} / {device['name']}.", flush=True)
        if options.app:
            app = options.app.resolve()
        else:
            print("Building the signed Debug simulator app.", flush=True)
            command = ["xcodebuild", "-project", "DemoApp/CodexKitDemo.xcodeproj",
                       "-scheme", "CodexKitIOSDemo", "-configuration", "Debug",
                       "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(derived),
                       "-onlyUsePackageVersionsFromResolvedFile",
                       "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
            if options.build_only:
                command += ["ONLY_ACTIVE_ARCH=NO", "ARCHS=arm64 x86_64"]
            else:
                command += ["ONLY_ACTIVE_ARCH=YES", f"ARCHS={platform.machine()}"]
            with timings.measure("build"), (output / "build.log").open("w") as log:
                run(command + ["build"], log=log, timeout=1800)
            app = derived / "Build/Products/Debug-iphonesimulator/CodexKitIOSDemo.app"
        with (app / "Info.plist").open("rb") as source:
            bundle_id = plistlib.load(source)["CFBundleIdentifier"]
        if options.build_only:
            print(f"Signed universal simulator app built: {app}", flush=True)
            return 0
        setup_start = time.monotonic()
        simulator = run(["xcrun", "simctl", "create", f"CodexKit verification {run_id}",
                         device["identifier"], runtime["identifier"]])
        (output / "run.json").write_text(json.dumps({"runID": run_id, "runtime": runtime["name"],
            "device": device["name"], "simulatorID": simulator, "bundleID": bundle_id}, indent=2) + "\n")
        print("Booting the temporary simulator.", flush=True)
        run(["xcrun", "simctl", "boot", simulator])
        with (output / "boot.log").open("w") as log:
            run(["xcrun", "simctl", "bootstatus", simulator, "-b"], log=log, timeout=300)
        run(["xcrun", "simctl", "install", simulator, str(app)], timeout=180)
        print("Locating the installed app's data container before launch.", flush=True)
        with (output / "container.log").open("w") as log:
            container = resolve_app_container(simulator, bundle_id, log=log)
        timings.record("simulator_setup", time.monotonic() - setup_start)
        report_path = container / "Documents/CodexKitVerification.json"
        environment = dict(os.environ, SIMCTL_CHILD_CODEXKIT_VERIFICATION_RUN_ID=run_id)
        mode_arguments = ["--verify-smoke"] if options.mode == VerificationMode.SMOKE else []
        verification_start = time.monotonic()
        run(["xcrun", "simctl", "launch", "--terminate-running-process",
             f"--stdout={output / 'app-stdout.log'}", f"--stderr={output / 'app-stderr.log'}",
             simulator, bundle_id, "--verify-runtime", "--verify-local-only"] + mode_arguments, env=environment)
        print("Waiting for SQLite, Realm, completion, and cancellation checks.", flush=True)
        deadline = time.monotonic() + options.report_timeout
        while time.monotonic() < deadline:
            if report_path.is_file():
                report_bytes = report_path.read_bytes()
                (output / "CodexKitVerification.json").write_bytes(report_bytes)
                validate_report(json.loads(report_bytes), run_id, options.mode)
                run(["xcrun", "simctl", "terminate", simulator, bundle_id])
                run(["xcrun", "simctl", "launch", simulator, bundle_id,
                     "--verify-runtime", "--verify-local-only", "--verify-recovery-reopen"] + mode_arguments, env=environment)
                reopen_path = container / "Documents/CodexKitRecoveryReopen.json"
                reopen_deadline = time.monotonic() + options.report_timeout
                while not reopen_path.is_file() and time.monotonic() < reopen_deadline:
                    time.sleep(1)
                if not reopen_path.is_file():
                    raise RuntimeError("Cold recovery verification did not report a result.")
                reopened = json.loads(reopen_path.read_bytes())
                (output / "CodexKitRecoveryReopen.json").write_text(json.dumps(reopened, indent=2) + "\n")
                if (reopened.get("runID") != run_id or reopened.get("passed") != "true"
                        or not reopened.get("finishedAt") or reopened.get("mode") != options.mode):
                    raise RuntimeError(f"Cold recovery failed: {reopened}")
                timings.record("execution_and_relaunch", time.monotonic() - verification_start)
                print(f"Simulator {options.mode} verification passed: adapters, cancellation, and receipt recovery after app relaunch; no live access.", flush=True)
                return 0
            time.sleep(1)
        raise RuntimeError(f"No verification report arrived within {options.report_timeout} seconds.")
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        (output / "failure.txt").write_text(str(error) + "\n")
        print(str(error), file=sys.stderr)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            message = str(error)[:12000].replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=Simulator verification::{message}")
        return 1
    except KeyboardInterrupt:
        print("Simulator verification interrupted.", file=sys.stderr)
        return 130
    finally:
        if simulator:
            # Only this run's newly created device can be shut down or deleted.
            for action in ("shutdown", "delete"):
                try:
                    subprocess.run(["xcrun", "simctl", action, simulator], timeout=60,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except (OSError, subprocess.TimeoutExpired):
                    print(f"Could not {action} temporary simulator {simulator}.", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
