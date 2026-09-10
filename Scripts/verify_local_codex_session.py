#!/usr/bin/env python3
"""Build and ad-hoc sign a macOS probe using synthetic credentials in a fresh home."""
from pathlib import Path
import json
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    subprocess.run(["swift", "build", "--target", "CodexKit"], cwd=ROOT, check=True)
    output = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip()
    binary_dir = Path(output)
    with tempfile.TemporaryDirectory(prefix="codexkit-auth-probe-") as temporary:
        app = Path(temporary) / "CodexKitAuthProbe.app"
        executable = app / "Contents/MacOS/CodexKitAuthProbe"
        executable.parent.mkdir(parents=True)
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "org.codexkit.synthetic-auth-probe",
                          "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL",
                          "CFBundleVersion": "1"}, handle)
        output_map = json.loads((binary_dir / "CodexKit.build/output-file-map.json").read_text())
        objects = [Path(outputs["object"]) for source, outputs in output_map.items()
                   if source and "object" in outputs and Path(source).is_file()]
        if not objects:
            raise RuntimeError("CodexKit object files were not found")
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                        "-I", str(binary_dir / "Modules"),
                        str(ROOT / "Scripts/VerifyLocalCodexSession.swift"),
                        *map(str, objects), "-o", str(executable)], cwd=ROOT, check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
