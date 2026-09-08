import importlib.util
from pathlib import Path
import unittest

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

    @staticmethod
    def runtime(version):
        return dict(identifier="com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-"),
                    version=version, name="iOS " + version, isAvailable=True,
                    supportedDeviceTypes=[dict(identifier="iPhone-test", productFamily="iPhone", name="iPhone")])


if __name__ == "__main__":
    unittest.main()
