# Working on Herdr companion

Use the installation and verification commands in README.md. The server, native
clients, web client, and Pi extensions share one API contract. Keep them compatible.

Machine-specific settings belong in the operator's private configuration file.
Use config.example.toml and entirely synthetic data in source, tests, screenshots,
and documentation. Never copy a filled-in configuration or captured session into
this repository. Run scripts/check-public-source.py before committing.

For requested deliveries, diagnose and fix build, test, and configuration failures
within the requested scope. Preserve legitimate validation and authentication
checks. Report the delivered revision, verification, and how to find or test any
notable user-facing changes. Keep deployment identities and destinations private.

Do not add AI attribution or Co-Authored-By lines to commit messages.
