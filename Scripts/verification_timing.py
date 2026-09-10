"""Small build/setup/execution timing records shared by the demo harnesses."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import time


class Timings:
    def __init__(self, path):
        self.path = Path(path)
        self.values = {}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text("{}\n")

    @contextmanager
    def measure(self, name):
        start = time.monotonic()
        try:
            yield
        finally:
            self.record(name, time.monotonic() - start)

    def record(self, name, duration):
        seconds = round(duration, 3)
        self.values[name] = seconds
        self.path.write_text(json.dumps(self.values, indent=2) + "\n")
        print(f"TIMING {name}: {seconds:.3f}s", flush=True)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                summary.write(f"- {name}: **{seconds:.1f}s**\n")
