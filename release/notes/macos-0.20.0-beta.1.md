# macOS 0.20.0-beta.1

## Settings, reorganized into categories

- Mac Settings (⌘,) is now a two-column window. A left sidebar groups every preference into
  eight categories and the detail column shows only the selected one, so a setting is one click
  away instead of part of a single long scroll.
- The categories are **General** (text size and About), **Machines** (connection status and
  saved machines), **Agents** (agent, HUD, vision, and notes models; prompts; Smart Cleanup),
  **HUD**, **Alerts**, **Voice**, **Privacy & Access** (privacy guarantees, menu-bar session
  titles, agent control, and screen & system audio recording), and **Updates**.
- Nothing left the app and no control changed behavior. Every existing switch, picker, model
  menu, prompt override, button, keyboard shortcut, saved preference, and accessibility label
  is the same; only its location is grouped more clearly.
- The Settings window opens wider so the sidebar and a full category fit comfortably, and the
  category you choose stays selected while the app runs.

## Mac-only update

This release changes one Mac window. The companion server, CLI, Pi package, and their API
contracts are unchanged, so no companion update is required and no server deployment is
implied. Installed machines, saved chats, notes, tickets, and Keychain credentials are
untouched.

## Install and check it

In **Settings → Updates** (shown as **App updates** before this update), enable **Include
preview builds**, then choose **Herdr Companion → Check for Updates…**. Review the update and
let Sparkle install and relaunch the app.

Then open ⌘, and confirm: each sidebar category selects a matching detail pane; Agent models,
Prompts, and Smart Cleanup are under **Agents**; HUD size and the summon shortcut are under
**HUD**; agent control and screen recording permissions are under **Privacy & Access**; and
update checks are under **Updates**.

This preview uses Apple Development signing and is **not notarized**. It may require normal
macOS approval on first installation; do not disable Gatekeeper or other protections. No live
provider-quality test or server rollout is implied by this release.
