# Companion 0.64.1b1

Adds `completed` as an archive reason and **Completed** to the web archive menu. The reason is retained with the archived feature; workflow status, running work, and history are unchanged. No database migration is required.

This companion update is separate from the Mac updater. Follow the README standalone installation procedure to install the wheel into the companion environment and restart its service, preserving private configuration and state. Install it before selecting Completed in Mac 0.64.1-beta.1. Older clients and all previous archive reasons remain compatible.

The package includes the previous release's longer First Mate coordinator budgets. Existing explicit private settings and dispatched job budgets remain authoritative. To roll back, reinstall the preceding wheel with the same private configuration and state directory.
