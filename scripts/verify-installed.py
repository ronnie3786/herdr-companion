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
        resources = json.loads(run("import json; import herdr_harness; from herdr_harness.resources import pi_extension_path, configuration_example; from herdr_harness.agent_docs import docs_root; from pathlib import Path; p=Path(herdr_harness.__file__).parent; d=docs_root(); print(json.dumps({'installed': 'site-packages' in str(p), 'pi': (pi_extension_path({})/'extensions/send-to-herdr.ts').is_file(), 'awareness': (pi_extension_path({})/'extensions/companion-awareness.ts').is_file(), 'guides': all((d/name).is_file() for name in ('overview.md','control.md','first-mate.md','api.md')), 'sample': configuration_example().is_file(), 'web': (p/'static/herdr-web/index.html').is_file()}))"))
        assert all(resources.values()), resources
        lineage = run("from herdr_harness.resources import pi_extension_path; p=pi_extension_path({}); assert (p/'lib/session-lineage.ts').is_file(); assert '../lib/session-lineage' in (p/'extensions/pi-semantic-bridge.ts').read_text(); assert (p/'extensions/session-context-discovery.ts').is_file(); print('ok')")
        assert lineage.strip() == "ok"
        session_context_entry = run("from importlib.metadata import distribution; eps=distribution('herdr-companion').entry_points; assert any(e.name == 'herdr-session-context' and e.value == 'herdr_harness.commands:session_context' for e in eps); print('ok')")
        assert session_context_entry.strip() == "ok"
        pr_review_entry = run("from importlib.metadata import distribution; eps=distribution('herdr-companion').entry_points; assert any(e.name == 'herdr-pr-review' and e.value == 'herdr_harness.commands:pr_review' for e in eps); print('ok')")
        assert pr_review_entry.strip() == "ok"
        docs_entry = run("from importlib.metadata import distribution; eps=distribution('herdr-companion').entry_points; assert any(e.name == 'herdr-docs' and e.value == 'herdr_harness.agent_docs:main' for e in eps); print('ok')")
        assert docs_entry.strip() == "ok"
        docs_cli = json.loads(run("import json, subprocess, sys; from pathlib import Path; cwd=Path.cwd(); empty=not any(cwd.iterdir()); exe=Path(sys.executable).with_name('herdr-docs'); help_text=subprocess.check_output([str(exe),'--help'], cwd=cwd, text=True); listing=subprocess.check_output([str(exe),'list'], cwd=cwd, text=True); topic=subprocess.check_output([str(exe),'read','overview'], cwd=cwd, text=True); first_mate=subprocess.check_output([str(exe),'read','first-mate'], cwd=cwd, text=True); first_mate_path=Path(subprocess.check_output([str(exe),'path','first-mate'], cwd=cwd, text=True).strip()); print(json.dumps({'empty': empty, 'help': 'Read Herdr Companion agent references offline' in help_text, 'topics': len(json.loads(listing)['topics']), 'overview': topic.startswith('# Herdr Companion agent overview'), 'firstMate': first_mate.startswith('# First Mate agent reference'), 'firstMatePath': first_mate_path.is_absolute() and first_mate_path.is_file()}))"))
        assert all(docs_cli.values()) and docs_cli["topics"] == 4, docs_cli
        first_mate = json.loads(run("""
import json
from pathlib import Path
import herdr_harness
from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_store import FirstMateStore
from herdr_harness.resources import pi_extension_path
package = Path(herdr_harness.__file__).parent
extension = pi_extension_path({}) / 'extensions/first-mate.ts'
store = FirstMateStore(Path.cwd() / 'first-mate-check.sqlite3')
runtime = FirstMateRuntime(store, environ={}, runtime_root=Path.cwd() / 'first-mate-check-runs')
print(json.dumps({
    'installed_extension': extension.is_file() and '_bundled' in extension.parts,
    'runtime_extension': runtime.extension == extension,
    'typed_tools': 'fm_delegate' in extension.read_text(),
    'html': (package / 'static/first-mate/index.html').is_file(),
    'javascript': (package / 'static/first-mate/app.js').is_file(),
    'empty_store': store.list_features() == [],
}))
store.close()
"""))
        assert all(first_mate.values()), first_mate
        for module in ("herdr_harness.configuration_cli", "herdr_harness.control_cli", "herdr_commands.setup_herdr_demo", "herdr_commands.herdr_active_work_sync", "herdr_commands.herdr_pr_review_watch", "herdr_commands.herdr_hud_chats_cli", "herdr_commands.herdr_session_context_cli", "herdr_commands.herdr_first_mate_cli"):
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
                for path in ("/herdr-web/", "/first-mate/", "/api/v1/config/machines", "/api/v1/notes", "/api/v1/hud-chats", "/api/v1/first-mate/features", "/api/v1/first-mate/capabilities", "/api/v1/pr-reviews/capabilities"):
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
    print("Installed wheel: resources and offline guides, First Mate runtime/extension, CLI entry points, authenticated API, web assets, isolated state, and clean shutdown passed.")


if __name__ == "__main__":
    main()
