#!/usr/bin/env python3
"""Exercise a wheel installation from an empty directory with isolated state."""
from pathlib import Path
import argparse
import json
import os
import secrets
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", required=True, help="Python in a clean environment containing only the installed wheel")
    args = parser.parse_args()
    python = str(Path(args.python).absolute())
    with tempfile.TemporaryDirectory(prefix="herdr-installed-") as directory:
        root = Path(directory)
        env = {"HOME": directory, "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "en_US.UTF-8", "PYTHONUNBUFFERED": "1"}
        def run(code, *arguments):
            return subprocess.check_output([python, "-I", "-c", code, *arguments], cwd=root, env=env, stderr=subprocess.STDOUT, timeout=30).decode()
        resources = json.loads(run("import json; import herdr_harness; from herdr_harness.resources import pi_extension_path, configuration_example; from pathlib import Path; p=Path(herdr_harness.__file__).parent; print(json.dumps({'installed': 'site-packages' in str(p), 'pi': (pi_extension_path({})/'extensions/send-to-herdr.ts').is_file(), 'sample': configuration_example().is_file(), 'web': (p/'static/herdr-web/index.html').is_file()}))"))
        assert all(resources.values()), resources
        for module in ("herdr_harness.configuration_cli", "herdr_commands.setup_herdr_demo", "herdr_commands.herdr_active_work_sync", "herdr_commands.herdr_pr_review_watch"):
            run(f"from {module} import main; raise SystemExit(main())", "--help")
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        token = secrets.token_hex(32)
        config = root / "config.toml"
        config.write_text(f'version = 1\n[server]\nhost = "127.0.0.1"\nport = {port}\napi_token = "{token}"\nstate_dir = "{root / "state"}"\nsocket_path = "{root / "absent.sock"}"\nno_browser = true\n')
        config.chmod(0o600)
        base = f"http://127.0.0.1:{port}"
        log = root / "server.log"
        with log.open("wb") as output:
            process = subprocess.Popen([python, "-I", "-c", "from herdr_dashboard import main; raise SystemExit(main())", "--config", str(config)], cwd=root, env=env, stdout=output, stderr=output)
            try:
                deadline = time.monotonic() + 20
                while True:
                    if process.poll() is not None:
                        raise AssertionError("Installed server exited before becoming ready")
                    try:
                        request = urllib.request.Request(base + "/api/v1/health", headers={"Authorization": "Bearer " + token})
                        with urllib.request.urlopen(request, timeout=2) as response:
                            assert response.status == 200
                            json.load(response)
                        break
                    except (OSError, urllib.error.URLError):
                        if time.monotonic() >= deadline:
                            raise AssertionError("Installed server did not become ready") from None
                        time.sleep(0.1)
                try:
                    urllib.request.urlopen(base + "/api/v1/health", timeout=2)
                    raise AssertionError("Control API accepted a request without credentials")
                except urllib.error.HTTPError as error:
                    assert error.code == 401
                for path in ("/herdr-web/", "/api/v1/config/machines", "/api/v1/notes"):
                    request = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + token})
                    with urllib.request.urlopen(request, timeout=2) as response:
                        assert response.status == 200, path
                assert list((root / ".local/share/herdr-companion/connections").glob("*.json"))
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise AssertionError("Installed server did not shut down cleanly") from None
        assert process.returncode == 0, "Installed server returned a nonzero exit status"
        assert not list((root / ".local/share/herdr-companion/connections").glob("*.json"))
        assert token not in log.read_text(), "Server log contains a credential"
    print("Installed wheel: resources, CLI entry points, authenticated API, web assets, isolated state, and clean shutdown passed.")


if __name__ == "__main__":
    main()
