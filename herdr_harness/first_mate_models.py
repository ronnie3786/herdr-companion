"""Read Pi's authenticated model catalog without prompting a model or saving a session."""
from __future__ import annotations
import json
import os
import selectors
import subprocess
import time
from .child_environment import agent_environment
from .first_mate_store import FirstMateError


def read_model_catalog(pi_bin, environ, cwd):
    if not pi_bin:
        raise FirstMateError("Pi is not available on this host", code="model_catalog_unavailable", status=503)
    # Never forward full model objects: they can contain private URLs and headers.
    # The picker needs the configured catalog, not Pi's background network
    # refresh. Stopping that refresh can strand its auth lock for 30 seconds,
    # blocking the coordinator launched immediately after a model selection.
    # This flag is scoped to discovery; actual agent turns still run online.
    command = [pi_bin, "--offline", "--mode", "rpc", "--no-session", "--no-extensions", "--no-skills",
               "--no-prompt-templates", "--no-context-files", "--no-builtin-tools"]
    process = None
    selector = selectors.DefaultSelector()
    try:
        process = subprocess.Popen(command, cwd=cwd, env=agent_environment(environ, integration=False),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        process.stdin.write(b'{"id":"catalog","type":"get_available_models"}\n')
        process.stdin.flush()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline, buffer, total = time.monotonic() + 15, b"", 0
        while time.monotonic() < deadline:
            if not selector.select(timeout=max(0, deadline - time.monotonic())):
                break
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > 8 * 1024 * 1024:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    response = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(response, dict) or response.get("id") != "catalog":
                    continue
                if response.get("success") is not True:
                    break
                models = []
                for model in response.get("data", {}).get("models", []):
                    if not isinstance(model, dict):
                        continue
                    provider, identity = model.get("provider"), model.get("id")
                    if not isinstance(provider, str) or not isinstance(identity, str):
                        continue
                    models.append({"id": provider + "/" + identity,
                                   "name": str(model.get("name") or identity)[:300],
                                   "provider": provider, "reasoning": bool(model.get("reasoning"))})
                return {"models": sorted(models, key=lambda m: (m["provider"], m["name"])),
                        "default_model": environ.get("HERDR_FIRST_MATE_MODEL", ""),
                        "thinking_levels": ["off", "minimal", "low", "medium", "high", "xhigh", "max"]}
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    finally:
        selector.close()
        if process:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
            for pipe in (process.stdin, process.stdout):
                if pipe:
                    pipe.close()
    raise FirstMateError("Could not read Pi models. Check Pi and provider setup on this host, then retry.",
                         code="model_catalog_unavailable", status=503)
