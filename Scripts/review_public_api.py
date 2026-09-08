#!/usr/bin/env python3
"""Compare the core/UI public Swift API with a local release ref without changing the checkout."""
import argparse
import json
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(args, log=None):
    result = subprocess.run(args, cwd=ROOT, check=True, text=True,
                            stdout=log or subprocess.PIPE, stderr=subprocess.STDOUT)
    return (result.stdout or "").strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="Existing local release tag or commit.")
    parser.add_argument("--output-dir", type=Path, default=ROOT / ".build/api-review")
    options = parser.parse_args()
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    baseline = run(["git", "rev-parse", "--verify", options.baseline + "^{commit}"])
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"])
    target = platform.machine() + "-apple-macosx14.0"
    modules = ["CodexKit", "CodexKitUI"]
    for version in ("baseline", "current"):
        directory = output / version
        directory.mkdir(exist_ok=True)
        for module in modules:
            if version == "baseline":
                paths = run(["git", "ls-tree", "-r", "--name-only", baseline, "--", f"Sources/{module}"]).splitlines()
                sources = []
                for name in paths:
                    if not name.endswith(".swift"):
                        continue
                    destination = directory / name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_text(run(["git", "show", f"{baseline}:{name}"]) + "\n")
                    sources.append(str(destination))
            else:
                sources = [str(p) for p in sorted((ROOT / "Sources" / module).rglob("*.swift"))]
            print(f"Compiling {version} {module} API.", flush=True)
            with (directory / f"{module}-compile.log").open("w") as log:
                run(["xcrun", "swiftc", "-emit-module", "-parse-as-library", "-module-name", module,
                     "-package-name", "CodexKit", "-swift-version", "6", "-target", target, "-sdk", sdk,
                     "-module-cache-path", str(output / "module-cache"), "-I", str(directory),
                     "-emit-module-path", str(directory / f"{module}.swiftmodule"), *sources], log)
            run(["xcrun", "swift-api-digester", "-dump-sdk", "-module", module, "-I", str(directory),
                 "-sdk", sdk, "-target", target, "-module-cache-path", str(output / "module-cache"),
                 "-avoid-location", "-avoid-tool-args", "-o", str(directory / f"{module}.json")])
    for module in modules:
        with (output / f"{module}-changes.txt").open("w") as log:
            run(["xcrun", "swift-api-digester", "-diagnose-sdk", "-disable-fail-on-error",
                 "-input-paths", str(output / "baseline" / f"{module}.json"),
                 "-input-paths", str(output / "current" / f"{module}.json")], log)
    (output / "review.json").write_text(json.dumps({"baselineRef": options.baseline, "baselineCommit": baseline,
        "modules": modules, "target": target, "scope": "Public source API; diagnostics require review, not an ABI guarantee."}, indent=2) + "\n")
    print(f"Public API diagnostics written to {output}.")


if __name__ == "__main__":
    main()
