"""Error type shared by every Code Factory layer."""

from __future__ import annotations


class CodeFactoryError(RuntimeError):
    """A recoverable Code Factory failure carrying a machine-readable ``code``.

    Codes used across the package (non-exhaustive):

    - ``invalid_settings``  – configuration is missing or malformed.
    - ``invalid_request``   – a caller passed an argument outside the accepted bounds.
    - ``not_found``         – a ledger record does not exist.
    - ``github_failed``     – a ``gh`` invocation exited non-zero or returned bad JSON.
    - ``download_failed``   – an attachment download was refused or too large.
    - ``git_failed``        – a ``git`` invocation exited non-zero.
    - ``pi_failed``         – a Pi session could not be started at all.
    """

    def __init__(self, message: str, *, code: str = "code_factory_error"):
        super().__init__(message)
        self.code = code
