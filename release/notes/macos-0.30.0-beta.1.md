# Herdr Companion 0.30.0 Preview 1

## First Mate usage and cost

- See each task's total estimated USD cost beside its ticket label in the First Mate sidebar.
- Open **Overview** for recorded model, token, and cost breakdowns across the task.
- Open **Agents** and saved session history for each agent's own cost, its child-tree total, and individual session usage. Coordinator history, nested workers, retries, handoff sessions, and watchdog/recovery advisors are included in the task total without counting a reused session twice.
- Totals cover the full retained managed session inventory, even when the displayed history is truncated. Existing saved usage is collected without starting additional model requests.
- Missing or incomplete cost records are marked unavailable or partial. These are Pi-reported estimates, not provider invoices; subscription providers can report zero. Arbitrary unregistered sessions and external-service charges cannot be attributed to the task.

## Compatibility and setup

The Mac app remains compatible with older companion servers, but usage requires the separately published **companion 0.30.0b1** package advertising `first-mate-usage-v1` on each task's host. Updating the Mac app alone does not install or restart the companion server. Preserve your private configuration and state and follow the documented server update procedure when installing that package. The updated server uses additive API fields and remains compatible with existing clients.

Use **Herdr Companion → Check for Updates…** to review and install this Mac preview. Then open **First Mate**, select a task, and compare its sidebar total with Overview. Inspect an agent's saved sessions to see the models and costs behind its subtotal.
