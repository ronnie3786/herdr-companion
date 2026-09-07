# Roadmap

Herdr is an experimental personal tool. These are topics to revisit, not release
commitments or promised dates.

## Contextual question assistant

**Status:** Initial implementation complete; private validation and rollout in progress.

A reusable question conversation component supports Git selection, HUD, and Notes.
The initial question profile uses supplied context with tools disabled. Scoped
repository tools, iOS adoption, and streaming remain follow-up work.

The architecture describes a reusable question conversation component for Git selections, the
floating Mac HUD, and additional features. Presenting features provide structured
location and context; shared infrastructure handles conversations, recovery, and
an explicit handoff to an agent for actions.

See the [architecture and implementation plan](docs/contextual-assistant-architecture.md)
for existing integration points, the proposed context/API contract, compatibility,
and phased acceptance criteria.

## Reassess the web companion

**Status:** Deferred. Direction undecided.

The standalone browser interface needs attention. Before investing in it,
decide whether it has a useful role alongside the native Mac and iPhone apps.

- **Improve it:** Define its intended users and core workflows, review its current
  usability and feature gaps, then refresh the interface and verify those workflows.
- **Deprecate it:** Stop developing the standalone browser experience and document
  its limitations and the recommended alternatives.
- **Remove it:** Retire the standalone browser experience if maintaining it no
  longer makes sense, with a clear migration path for any users.

Before choosing a direction, inventory shared web dependencies. The Mac app
currently embeds the web companion’s Git changes view. Retiring the browser
interface must preserve that functionality, either by retaining the shared Git
view or replacing it before removing the code. Check server packaging, routes,
tests, and documentation as part of any removal.

**Next step when revisited:** Evaluate actual usage and maintenance cost, then
record a decision and a scoped implementation plan. No web redesign or removal
is scheduled yet.
