#!/usr/bin/env python3
"""Run one shard of the Python test suite, so Verify can run the shards in parallel.

Test modules are dealt to shards slowest first, each going to the shard with the
least estimated time so far. Estimates come from ci-unittest-weights.json (seconds
per module, measured with --measure); a module missing from it is estimated from
its file size. Every module lands in exactly one shard, and modules are loaded
exactly as `python -m unittest discover -s tests` names them.

Usage: ci-unittest-shard.py INDEX COUNT     (INDEX counts from 1)
       ci-unittest-shard.py --list COUNT    (print every shard's modules and estimate)
       ci-unittest-shard.py --measure       (time every module and rewrite the weights)
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "tests"
WEIGHTS = Path(__file__).with_name("ci-unittest-weights.json")


def estimates(paths: list[Path], weights: dict[str, float]) -> dict[str, float]:
    known = [path for path in paths if path.stem in weights]
    size = sum(path.stat().st_size for path in known)
    per_byte = sum(weights[path.stem] for path in known) / size if size else 1.0
    return {path.stem: weights.get(path.stem, path.stat().st_size * per_byte) for path in paths}


def shards(paths: list[Path], count: int, weights: dict[str, float] | None = None) -> list[list[str]]:
    cost = estimates(paths, weights or {})
    bins: list[list[str]] = [[] for _ in range(count)]
    load = [0.0] * count
    for name in sorted(cost, key=lambda item: (-cost[item], item)):
        lightest = load.index(min(load))
        bins[lightest].append(name)
        load[lightest] += cost[name]
    return [sorted(names) for names in bins]


def load_weights() -> dict[str, float]:
    try:
        return {str(key): float(value) for key, value in json.loads(WEIGHTS.read_text()).items()}
    except (OSError, ValueError, AttributeError):
        return {}


def measure(modules: list[Path]) -> int:
    def timed(name: str) -> tuple[str, float]:
        started = time.monotonic()
        subprocess.run([sys.executable, "-m", "unittest", f"tests.{name}"], cwd=ROOT, capture_output=True)
        return name, round(time.monotonic() - started, 1)
    with ThreadPoolExecutor(6) as pool:
        weights = dict(pool.map(timed, [path.stem for path in modules]))
    WEIGHTS.write_text(json.dumps(weights, indent=1, sort_keys=True) + "\n")
    print(f"Measured {len(weights)} modules into {WEIGHTS.name}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--measure", action="store_true")
    parser.add_argument("values", nargs="*", type=int)
    args = parser.parse_args(argv)
    modules = sorted(TESTS.glob("test*.py"))
    if args.measure:
        return measure(modules)
    weights = load_weights()
    if args.list:
        cost = estimates(modules, weights)
        for number, names in enumerate(shards(modules, args.values[0], weights), 1):
            print(f"{number}: ~{sum(cost[name] for name in names):.0f}s {' '.join(names)}")
        return 0
    if len(args.values) != 2 or not 1 <= args.values[0] <= args.values[1]:
        parser.error("pass INDEX COUNT with 1 <= INDEX <= COUNT")
    index, count = args.values
    names = shards(modules, count, weights)[index - 1]
    print(f"Shard {index}/{count}: {len(names)} of {len(modules)} test modules", flush=True)
    # As `python -m unittest discover -s tests` from the repository root: modules import
    # each other both as `test_x` and as `tests.test_x`.
    sys.path[:0] = [str(TESTS), str(ROOT)]
    suite = unittest.defaultTestLoader.loadTestsFromNames(names)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
