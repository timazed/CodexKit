import importlib.util
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
                     localAdapters="passed", liveProvider="skipped: local_only")
        verifier.validate_report(valid, "current")
        for key in ("sqlite", "realm", "localAdapters"):
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
            app = derived / "Build/Products/Debug-iphonesimulator/AssistantRuntimeDemoApp.app"
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

    def test_prebuilt_app_verification_never_resolves_or_builds_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Signed.app"
            self.make_app(app)
            container = root / "container"
            (container / "Documents").mkdir(parents=True)
            report = dict(runID="fresh", finishedAt="finished", sqlite="passed", realm="passed",
                          localAdapters="passed", liveProvider="skipped: local_only")
            (container / "Documents/CodexKitVerification.json").write_text(json.dumps(report))

            def simulated_run(command, **_kwargs):
                self.assertEqual(command[:2], ["xcrun", "simctl"])
                if command[2] == "list":
                    return json.dumps(dict(runtimes=[self.runtime("17.0.1")]))
                if command[2] == "create":
                    return "owned-simulator"
                if command[2] == "get_app_container":
                    return str(container)
                return ""

            output = root / "reports"
            args = ["verify", "--app", str(app), "--runtime", "17.0.1", "--output-dir", str(output)]
            with patch.object(verifier.sys, "argv", args), patch.object(verifier.signal, "signal"), \
                 patch.object(verifier.uuid, "uuid4", return_value="fresh"), \
                 patch.object(verifier, "run", side_effect=simulated_run) as run, \
                 patch.object(verifier.subprocess, "run") as cleanup:
                self.assertEqual(verifier.main(), 0)
            self.assertEqual(json.loads((output / "CodexKitVerification.json").read_text()), report)
            installs = [call.args[0] for call in run.call_args_list if call.args[0][2] == "install"]
            self.assertEqual(installs, [["xcrun", "simctl", "install", "owned-simulator", str(app.resolve())]])
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
