# Companion 0.27.0b3

PR Review starts Pi skills without a project-trust prompt in its managed checkout.
Runs use the host's global Pi settings and installed skills, while ignoring
checkout-local Pi settings, extensions, and skills. Install review skills globally
under `~/.agents/skills/` or Pi's user skill directory.

An idle terminal no longer falsely marks a skill run finished. Automatic
completion requires an explicit terminal `done` status; manual completion remains
available in Agents.

This is a compatible companion server update and does not require a Mac app update.
