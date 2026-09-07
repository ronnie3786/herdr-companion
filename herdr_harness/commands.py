"""Installed CLI entry points share the same local cluster configuration."""
import argparse
import os
import sys

from .config import ConfigurationError, load_configuration
from .connection_info import connection_environment


def _run(module_name):
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument("--config")
    parser.add_argument("--machine")
    selected, arguments = parser.parse_known_args()
    try:
        environment = os.environ if selected.config or selected.machine else connection_environment(os.environ)
        configuration = load_configuration(selected.config, selected.machine, environ=environment)
    except ValueError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        return 2
    from importlib import import_module
    try:
        command = import_module("herdr_commands." + module_name)
    except ModuleNotFoundError as exc:
        if exc.name not in {"herdr_commands", "herdr_commands." + module_name}:
            raise
        command = import_module("scripts." + module_name)
    return command.main(arguments, environ=configuration.environ)


def notes():
    return _run("herdr_notes_cli")


def active_work():
    return _run("herdr_active_work_cli")
