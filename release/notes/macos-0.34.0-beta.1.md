# Herdr Companion 0.34.0 Preview 1

## First Mate architect reviews

- Ask First Mate for an architect review, an architecture/design review, or a second opinion on an implementation. It delegates that work through the new **Architect** model role, independent of the workflow stage.
- Each companion host has its own architect model and thinking settings. Existing planning, execution, and coordinator settings are unchanged. First Mate's model settings show the host's architect pin; feature-level coordinator choices do not override it.
- Model details distinguish the **Requested** policy from the **Actual** model and thinking observed by Pi. The profile and exact saved session make routing checkable. Missing evidence is not presented as confirmed execution.

Architect work requires an explicitly configured host model. An absent pin or a startup model/thinking mismatch stops the dispatch with a visible error rather than silently using another model.

## Compatibility and installation

Use **Herdr Companion → Check for Updates…** to install this signed preview.

The separately published **companion 0.34.0b1** server package and its bundled Pi extension are required on each host for architect routing and startup enforcement. Configure `architect_model` and optional `architect_thinking` under the host's private `[first_mate]` settings. Use an exact provider-qualified model available to Pi on that host. No provider or paid model is enabled by public defaults.

Server updates are separate from the Mac updater. Follow the server update procedure, preserving configuration, state, and the previous runtime for rollback. Running workers keep their existing dispatch policy; new dispatches, retries, and continuations use the current host settings. Existing native clients remain compatible with the additive API fields. This release does not include an iOS binary.
