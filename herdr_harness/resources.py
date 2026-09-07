"""Locate source-tree or installed Herdr resources without external checkouts."""
from pathlib import Path
from typing import Mapping


def pi_extension_path(environ: Mapping[str, str]) -> Path | None:
    override = environ.get("HERDR_HARNESS_PI_EXTENSION_PATH")
    if override:
        candidate = Path(override).expanduser()
        if not (candidate / "package.json").is_file():
            raise ValueError("The configured Herdr Pi extension package is unavailable")
        return candidate
    package = Path(__file__).resolve().parent
    for candidate in (package / "_bundled/pi-semantic-bridge", package.parent / "pi-semantic-bridge"):
        if (candidate / "package.json").is_file():
            return candidate
    return None


def configuration_example() -> Path:
    package = Path(__file__).resolve().parent
    for candidate in (package / "_bundled/config.example.toml", package.parent / "config.example.toml"):
        if candidate.is_file():
            return candidate
    raise FileNotFoundError("The Herdr configuration example was not packaged")
