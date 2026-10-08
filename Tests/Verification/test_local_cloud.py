"""Old demo binaries must not silently pass the expanded end-to-end gate."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
from verify_local_cloud import validate_report


class LocalCloudReportTests(unittest.TestCase):
    def test_complete_remote_feature_report_passes(self):
        validate_report({"passed": True, "remoteJobCount": 16,
                         "simulatedPushDelivery": True, "checks": ["check"] * 16})

    def test_previous_demo_success_is_not_enough(self):
        with self.assertRaises(RuntimeError):
            validate_report({"passed": True, "checks": ["old cloud test"]})

    def test_partial_failed_and_missing_reports_fail(self):
        for report in [{}, {"passed": False, "error": "failed"},
                       {"passed": True, "remoteJobCount": 15, "simulatedPushDelivery": True, "checks": ["check"] * 16}]:
            with self.assertRaises(RuntimeError):
                validate_report(report)
