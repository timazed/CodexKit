#!/usr/bin/env python3
"""Require selected jobs to pass; only deliberately omitted jobs may be skipped."""
import json
import os

CORE_JOBS = ("sdk", "optimized")
EXTENDED_JOBS = ("demos", "build-minimum-simulator", "minimum-simulator")


def validate_results(needs):
    if needs.get("plan", {}).get("result") != "success":
        raise ValueError("Verification planning failed")
    extended = needs["plan"].get("outputs", {}).get("extended")
    if extended not in ("true", "false"):
        raise ValueError("Missing or invalid verification mode")
    for name in CORE_JOBS + EXTENDED_JOBS:
        expected = "success" if name in CORE_JOBS or extended == "true" else "skipped"
        if needs.get(name, {}).get("result") != expected:
            raise ValueError(f"{name} must be {expected}")


if __name__ == "__main__":
    validate_results(json.loads(os.environ["RESULTS"]))
    print("Every selected verification job passed")
