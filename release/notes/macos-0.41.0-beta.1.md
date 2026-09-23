# Herdr Companion 0.41.0 Preview 1

## A simpler Agent Profiles screen

- **Settings → Agent Profiles** (and **Fleet → Agent Profiles**) now opens on a row of machines, each showing the profile its agents use.
- One editor with **Soul** and **User** tabs shows the selected machine's profile. When another machine owns that profile, saving writes to the owner and refreshes every machine using it, so a shared Work profile can be edited from any machine that uses it.
- **Switch** chooses the machine's profile, creates a new one, or turns profiles off. Unused, empty starter profiles are tucked under **Empty Profiles**.
- **History**, **Add Notes for <machine>** (machine-only additions) and **Preview What Agents See** open in their own sheets.
- Agent-suggested edits appear as a banner; **Review** shows a line-by-line diff with **Approve** and **Decline**.
- Byte counters and required reason fields are gone. Saves record a short reason automatically, such as "Edited Soul".
- If a profile's owner is offline, its last synced copy stays readable until the owner is back. An unconfirmed change can be retried with the same request or abandoned; reloading stays available.

This release retains PR Review polish, Agent Profiles, and First Mate stability/recovery from the preceding previews.

## Compatibility

Mac-only change. It uses the existing `agent-profiles-v1` API, so companions from 0.38.0b1 onward work unchanged; no companion, CLI, Pi or iPhone update is needed. The Mac updater updates only the app.

## Quick test

1. Open **Settings → Agent Profiles**. Each machine chip should name the profile it uses.
2. Select a machine that uses a profile owned elsewhere. The header reads "Shared from …". Edit the User tab, press **Save** (⌘S), then select the owner machine and confirm the same text.
3. If a suggestion banner appears, choose **Review** and approve or decline it.
4. Open **History** and preview an earlier revision; open **Preview What Agents See**.

This preview uses Apple Development signing and signed Sparkle updates. It is not notarized.
