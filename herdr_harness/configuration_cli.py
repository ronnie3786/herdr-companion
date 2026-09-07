"""Initialize and validate private Herdr settings without printing credentials."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets
import sys

from .config import ConfigurationError, load_configuration
from .child_environment import agent_environment
from .resources import configuration_example


def initialize(path: Path) -> None:
    """Create a private file exclusively; never replace an existing setup."""
    sample = configuration_example().read_text(encoding="utf-8")
    marker = '# api_token = "replace-with-a-long-random-token"'
    if marker not in sample:
        raise ConfigurationError("The installed configuration example is missing its token marker")
    sample = sample.replace(marker, 'api_token = "' + secrets.token_hex(32) + '"', 1)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(sample)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("command", choices=("init", "check", "exec"))
    parser.add_argument("--config", type=Path, help="Private file; default ~/.config/herdr-companion/config.toml")
    parser.add_argument("--machine", help="Machine identifier from the private configuration")
    arguments = list(sys.argv[1:] if argv is None else argv)
    separator = arguments.index("--") if "--" in arguments else None
    command = arguments[separator + 1:] if separator is not None else []
    args = parser.parse_args(arguments[:separator] if separator is not None else arguments)
    if (args.command == "exec" and not command) or (args.command != "exec" and separator is not None):
        parser.error("Use herdr-config exec [--config PATH] [--machine ID] -- COMMAND [ARG ...]")
    try:
        if args.command == "init":
            path = (args.config or Path.home() / ".config/herdr-companion/config.toml").expanduser().absolute()
            initialize(path)
            print(f"Created private configuration: {path}")
            print("A random API token was generated inside the file. Edit the machine roster before sharing it privately.")
            return 0
        configuration = load_configuration(args.config, args.machine)
        if args.command == "exec":
            environment = agent_environment(configuration.environ)
            # No shell and no credentials in argv or output. The selected
            # command replaces this wrapper and inherits only agent settings.
            os.execvpe(command[0], command, environment)
            return 0
        print(json.dumps({
            "ok": True,
            "configured": configuration.path is not None,
            "machineSelected": configuration.machine is not None,
            "machineCount": len(configuration.public_machines()),
            "authenticationConfigured": bool(configuration.environ.get("HERDR_HARNESS_API_TOKEN")),
        }))
        return 0
    except FileExistsError:
        print("Configuration already exists; it was not changed.", file=sys.stderr)
    except (ConfigurationError, OSError) as exc:
        message = str(exc) if isinstance(exc, ConfigurationError) else "Cannot create or read the private configuration file."
        print(f"Configuration error: {message}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
