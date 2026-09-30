#!/usr/bin/env python3
"""Build and run the opt-in synthetic First Mate measurements on this Mac.

The test host uses synthetic models and a temporary native window. No installed
app, companion service, machine roster, or operator database is changed.
"""
import argparse
from pathlib import Path
import plistlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True, help="A new .xcresult path")
    parser.add_argument("--configuration", choices=("Debug", "Release"), default="Debug")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    derived = args.derived_data.resolve()
    if args.result.exists():
        parser.error("--result must be a new path")
    if not args.skip_build:
        subprocess.run([
            "xcodebuild", "-project", "herdr-harness-mac/herdr-harness-mac.xcodeproj",
            "-scheme", "herdr-harness-mac", "-configuration", args.configuration,
            "-destination", "platform=macOS", "-derivedDataPath", str(derived),
            "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=NO", "build-for-testing",
        ], cwd=root, check=True)
    products = derived / "Build/Products"
    candidates = sorted(products.glob("herdr-harness-mac_*.xctestrun"))
    if len(candidates) != 1:
        parser.error("Expected exactly one generated Mac xctestrun in the derived-data directory")
    with candidates[0].open("rb") as stream:
        spec = plistlib.load(stream)
    for configuration in spec["TestConfigurations"]:
        for target in configuration["TestTargets"]:
            if target["BlueprintName"] == "herdr-harness-macTests":
                target.setdefault("EnvironmentVariables", {})["HERDR_FIRST_MATE_BENCHMARK"] = "1"
    path = products / "first-mate-benchmark.xctestrun"
    with path.open("wb") as stream:
        plistlib.dump(spec, stream)
    subprocess.run([
        "xcodebuild", "test-without-building", "-xctestrun", str(path),
        "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
        "-only-testing:herdr-harness-macTests/FirstMatePerformanceMeasurements",
        "-resultBundlePath", str(args.result.resolve()),
    ], cwd=root, check=True)


if __name__ == "__main__":
    main()
