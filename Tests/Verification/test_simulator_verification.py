import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

source = Path(__file__).resolve().parents[2] / "Scripts/verify_ios_simulator.py"
spec = importlib.util.spec_from_file_location("simulator_verification", source)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class SimulatorVerificationTests(unittest.TestCase):
    def test_requires_each_adapter_and_local_only_mode(self):
        valid = dict(runID="current", finishedAt="finished", sqlite="passed", realm="passed",
                     localAdapters="passed", recovery="passed", liveProvider="skipped: local_only")
        verifier.validate_report(valid, "current")
        for key in ("sqlite", "realm", "localAdapters", "recovery"):
            for status in (None, "skipped", "failed: storage_error"):
                with self.subTest(key=key, status=status), self.assertRaises(RuntimeError):
                    verifier.validate_report(dict(valid, **{key: status}), "current")
        with self.assertRaises(RuntimeError):
            verifier.validate_report(dict(valid, liveProvider="passed"), "current")

    def test_rejects_stale_or_unfinished_report(self):
        for report in (dict(runID="old", finishedAt="finished"), dict(runID="current")):
            with self.assertRaises(RuntimeError):
                verifier.validate_report(report, "current")

    def test_selects_newest_available_iphone_runtime(self):
        old = self.runtime("18.6")
        current = self.runtime("26.5")
        unavailable = dict(self.runtime("27.0"), isAvailable=False)
        ipad_only = dict(self.runtime("28.0"), supportedDeviceTypes=[dict(productFamily="iPad")])
        runtime, phone = verifier.select_simulator([old, unavailable, current, ipad_only])
        self.assertEqual(runtime["version"], "26.5")
        self.assertEqual(phone["productFamily"], "iPhone")
        self.assertEqual(verifier.select_simulator([old, current], "18.6")[0], old)

    def test_missing_requested_runtime_fails_instead_of_using_another(self):
        with self.assertRaises(RuntimeError):
            verifier.select_simulator([self.runtime("18.6")], "17.0")

    def test_build_only_produces_a_portable_app_without_accessing_simulators(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            derived = root / "derived"
            app = derived / "Build/Products/Debug-iphonesimulator/CodexKitIOSDemo.app"
            self.make_app(app)
            args = ["verify", "--build-only", "--derived-data", str(derived),
                    "--output-dir", str(root / "reports")]
            with patch.object(verifier.sys, "argv", args), patch.object(verifier.signal, "signal"), \
                 patch.object(verifier, "run", return_value="") as run:
                self.assertEqual(verifier.main(), 0)
            self.assertEqual(run.call_count, 1)
            command = run.call_args.args[0]
            self.assertEqual(command[0], "xcodebuild")
            self.assertIn("ARCHS=arm64 x86_64", command)
            self.assertIn("ONLY_ACTIVE_ARCH=NO", command)

    def test_prebuilt_app_recovers_from_container_lookup_timeout_without_relaunching(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Signed.app"
            self.make_app(app)
            container = root / "container"
            (container / "Documents").mkdir(parents=True)
            report = dict(runID="fresh", finishedAt="finished", sqlite="passed", realm="passed",
                          localAdapters="passed", recovery="passed", liveProvider="skipped: local_only")
            (container / "Documents/CodexKitVerification.json").write_text(json.dumps(report))
            (container / "Documents/CodexKitRecoveryReopen.json").write_text(json.dumps(
                dict(runID="fresh", passed="true", finishedAt="finished")))
            clock = [0]
            lookups = []

            def simulated_run(command, **_kwargs):
                self.assertEqual(command[:2], ["xcrun", "simctl"])
                if command[2] == "list":
                    return json.dumps(dict(runtimes=[self.runtime("17.0.1")]))
                if command[2] == "create":
                    return "owned-simulator"
                if command[2] == "get_app_container":
                    lookups.append(command)
                    if len(lookups) == 1:
                        clock[0] += 60
                        raise subprocess.TimeoutExpired(command, 60)
                    return str(container)
                return ""

            output = root / "reports"
            args = ["verify", "--app", str(app), "--runtime", "17.0.1", "--output-dir", str(output)]
            with patch.object(verifier.sys, "argv", args), patch.object(verifier.signal, "signal"), \
                 patch.object(verifier.uuid, "uuid4", return_value="fresh"), \
                 patch.object(verifier.time, "monotonic", side_effect=lambda: clock[0]), \
                 patch.object(verifier.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                 patch.object(verifier, "run", side_effect=simulated_run) as run, \
                 patch.object(verifier.subprocess, "run") as cleanup:
                self.assertEqual(verifier.main(), 0)
            self.assertEqual(json.loads((output / "CodexKitVerification.json").read_text()), report)
            installs = [call.args[0] for call in run.call_args_list if call.args[0][2] == "install"]
            self.assertEqual(installs, [["xcrun", "simctl", "install", "owned-simulator", str(app.resolve())]])
            commands = [call.args[0][2] for call in run.call_args_list]
            self.assertEqual(commands.count("get_app_container"), 2)
            self.assertEqual(commands.count("launch"), 2)
            self.assertEqual(commands.count("terminate"), 1)
            self.assertLess(max(i for i, command in enumerate(commands) if command == "get_app_container"),
                            commands.index("launch"))
            self.assertEqual([call.args[0] for call in cleanup.call_args_list], [
                ["xcrun", "simctl", "shutdown", "owned-simulator"],
                ["xcrun", "simctl", "delete", "owned-simulator"],
            ])

    def test_container_lookup_deadline_bounds_retries_and_retains_the_timeout(self):
        clock = [0]

        def timed_out(command, *, timeout):
            clock[0] += timeout
            raise subprocess.TimeoutExpired(command, timeout)

        log = io.StringIO()
        with patch.object(verifier.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(verifier.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
             patch.object(verifier, "run", side_effect=timed_out) as run, \
             self.assertRaisesRegex(RuntimeError, "test.app on owned-simulator within 125 seconds.*timed out"):
            verifier.resolve_app_container("owned-simulator", "test.app", log=log, timeout=125)
        self.assertEqual(clock[0], 125)
        self.assertEqual([call.kwargs["timeout"] for call in run.call_args_list], [60, 60, 1])
        self.assertIn("Attempt 3", log.getvalue())
        self.assertIn("get_app_container", log.getvalue())

    def test_container_lookup_does_not_retry_command_failures(self):
        log = io.StringIO()
        with patch.object(verifier, "run", side_effect=RuntimeError("App is not installed")) as run, \
             patch.object(verifier.time, "sleep") as sleep, \
             self.assertRaisesRegex(RuntimeError, "App is not installed"):
            verifier.resolve_app_container("owned-simulator", "test.app", log=log)
        self.assertEqual(run.call_count, 1)
        sleep.assert_not_called()
        self.assertIn("App is not installed", log.getvalue())

    def test_container_lookup_rejects_empty_relative_and_missing_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            for value in ("", "relative/container", str(Path(directory) / "missing")):
                with self.subTest(value=value), patch.object(verifier, "run", return_value=value) as run, \
                     self.assertRaisesRegex(RuntimeError, "invalid data-container path"):
                    verifier.resolve_app_container("owned-simulator", "test.app", log=io.StringIO())
                self.assertEqual(run.call_count, 1)

    def test_failed_adapter_report_is_preserved_and_not_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Signed.app"
            self.make_app(app)
            container = root / "container"
            (container / "Documents").mkdir(parents=True)
            report = dict(runID="fresh", finishedAt="finished", sqlite="passed", realm="failed: storage_error",
                          localAdapters="failed", liveProvider="skipped: local_only")
            (container / "Documents/CodexKitVerification.json").write_text(json.dumps(report))
            output = root / "reports"
            args = ["verify", "--app", str(app), "--output-dir", str(output)]
            results = [json.dumps(dict(runtimes=[self.runtime("17.0.1")])), "owned-simulator",
                       "", "", "", str(container), ""]
            with patch.object(verifier.sys, "argv", args), patch.object(verifier.signal, "signal"), \
                 patch.object(verifier.uuid, "uuid4", return_value="fresh"), \
                 patch.object(verifier, "run", side_effect=results) as run, \
                 patch.object(verifier.subprocess, "run") as cleanup:
                self.assertEqual(verifier.main(), 1)
            self.assertIn("realm: failed: storage_error", (output / "failure.txt").read_text())
            self.assertEqual(json.loads((output / "CodexKitVerification.json").read_text()), report)
            commands = [call.args[0][2] for call in run.call_args_list]
            self.assertEqual(commands.count("launch"), 1)
            self.assertEqual(commands.count("get_app_container"), 1)
            self.assertEqual([call.args[0] for call in cleanup.call_args_list], [
                ["xcrun", "simctl", "shutdown", "owned-simulator"],
                ["xcrun", "simctl", "delete", "owned-simulator"],
            ])

    def test_build_failure_preserves_package_resolution_details_from_the_log(self):
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory) / "build.log").open("w") as log:
                log.write("xcodebuild: error: Could not resolve package dependencies:\n"
                          "package requires Swift tools 6.1 but installed version is 6.0\n")
                failed = subprocess.CompletedProcess(["xcodebuild", "-project"], 74)
                with patch.object(verifier.subprocess, "run", return_value=failed), \
                     self.assertRaisesRegex(RuntimeError, "requires Swift tools 6.1"):
                    verifier.run(["xcodebuild", "-project"], log=log)

    @staticmethod
    def make_app(app):
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier="test.app")))

    @staticmethod
    def runtime(version):
        return dict(identifier="com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-"),
                    version=version, name="iOS " + version, isAvailable=True,
                    supportedDeviceTypes=[dict(identifier="iPhone-test", productFamily="iPhone", name="iPhone")])


if __name__ == "__main__":
    unittest.main()
