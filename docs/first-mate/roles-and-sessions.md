# Roles, saved conversations, and compaction

First Mate is the primary cross-feature assistant and the product area. Each
feature has a **Second Mate**, explained in the UI as **Feature lead**. Its runtime
kind remains `coordinator` for API and saved-state compatibility. Delegated agents
are **workers** or **crewmates**. Architect and Research Scout are specialist
worker profiles, not separate process kinds.

An **Advisor** is automatically dispatched by watchdog/reliability or recovery
logic when an execution needs assessment. The human need not request one.
Advisors use the execution model policy. An **Architect** is explicitly selected
for an architecture review or implementation second opinion and requires its own
host model pin.

## Research Scout

Ask the First Mate or a feature's Second Mate to use Research Scout for a specific
ticket or question. Delegation uses `model_profile: research_scout`. The host must
provide these private configuration fields:

```toml
[machines.desktop.first_mate]
research_scout_model = "your-provider/your-research-model"
research_scout_thinking = "high"
research_scout_instructions_file = "~/.config/herdr-companion/agents/research-scout.md"
```

Keep company platforms, API commands, source locations, and research memory in
that private UTF-8 file. A thin personal Pi agent wrapper can reference the same
canonical file. Neither file belongs in public source. The runtime snapshots the
instructions into the private dispatch and passes a prompt-file path to Pi, so
company instructions do not appear in process arguments. A new dispatch adopts
updated instructions; a running dispatch keeps its snapshot.

The profile verifies the exact provider/model and optional thinking effort before
sending the task. Missing instructions, a missing pin, or a model mismatch blocks
the assignment instead of silently using another worker. Research produces a
source-backed summary and a self-contained HTML findings artifact. Ticket edits
remain drafts unless the human explicitly requested publication.

## Saved agent viewer

Managed agents are real Pi RPC sessions with retained native session IDs and
JSONL history. They do not create terminal panes, so they are not ordinary Herdr
Chat entries. Open an agent's saved session from First Mate to inspect its user
bubbles, collapsed Clanking activity, and final responses. The Mac viewer has no
composer. It refreshes saved messages while the dispatch writer is alive, shows
loading/waiting states, and can page backwards through history. Updates are saved
message updates, not token-by-token streaming.

First Mate resumes sessions itself across continuations and manager restarts.
The viewer does not transfer ownership to an interactive Pi terminal. For manual
investigation, work from a copy of a stopped session; do not attach another writer
to a conversation still owned by the manager.

## Compaction isolation

The supervisor must never call Pi's `set_auto_compaction` RPC to disable managed
compaction: Pi persists it into shared user settings. Instead, the extension's
validated managed-session hook cancels compaction for its coordinator, workers,
and advisors. Ordinary Pi sessions install no First Mate hook and retain their
own automatic compaction preference. Cancellation remains effective if optional
telemetry cannot be written.

Managed context rotation remains governed by `first_mate.context_target`
(150,000 by default) with model headroom. Ordinary Pi can compact at a lower
threshold than a model's advertised window using its private settings:

```json
{
  "compaction": {
    "enabled": true,
    "modelOverrides": {
      "your-provider/your-million-context-model": {
        "reserveTokens": 898576,
        "keepRecentTokens": 20000
      }
    }
  }
}
```

For a 1,048,576-token model, `contextWindow - reserveTokens` is 150,000.
Calculate the reserve from the actual configured window for each exact model;
leave unrelated models alone. This is a trigger after usage checks, not a strict
upper bound on an individual prompt or tool result. Pi also uses the reserve for
its summary output budget, bounded by the model's output limit. These model
overrides require a Pi version that supports `compaction.modelOverrides`.

After installing the corrected companion, restore `compaction.enabled` if the
old supervisor disabled it. Existing Pi processes must reload their settings or
restart. Update each affected host's companion separately; a source checkout or
Mac app update alone does not replace its installed runtime.
