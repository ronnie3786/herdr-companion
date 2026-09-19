"""Herdr Code Factory: an automated GitHub issue → worktree → PR → release pipeline.

The package is split into small, independently testable layers:

- ``settings``  – environment-driven configuration (``CodeFactorySettings``).
- ``store``     – the SQLite ledger that tracks issues, events, sessions and releases.
- ``github``    – a thin wrapper around the operator's authenticated ``gh`` CLI.
- ``git``       – worktree and branch operations against the configured checkout.
- ``pi``        – a headless Pi session runner that streams JSON events to a log.

Every layer accepts an injectable process runner so the test-suite never touches the
network, a real ``gh``, a real ``pi`` or the operator's own git configuration.
"""
