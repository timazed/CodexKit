#!/usr/bin/env python3
"""Select routine or comprehensive CI without network calls or cross-run waits."""
import argparse
import json
import os
from pathlib import Path


def verification_plan(event_name, event, force=False):
    extended = force or event_name == "schedule" or event.get("inputs", {}).get("extended") in (True, "true")
    profiles = [{"profile": "current", "runner": "macos-26"}]
    if extended:
        profiles.append({"profile": "minimum", "runner": "macos-15"})
    return {"extended": extended, "sdk_matrix": {"include": profiles}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true")
    options = parser.parse_args()
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    result = verification_plan(os.environ["GITHUB_EVENT_NAME"], event, options.force)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in result.items():
            output.write(f"{key}={json.dumps(value, separators=(',', ':'))}\n")
    print(json.dumps(result))
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        mode = "comprehensive" if result["extended"] else "routine"
        summary.write(f"Running fresh {mode} verification. Release publication requires comprehensive evidence.\n")


if __name__ == "__main__":
    main()
