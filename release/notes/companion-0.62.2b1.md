# Herdr Companion server 0.62.2b1

Corrects line wrapping in the shared web Git viewer's plain-text fallback. Wrap now keeps long lines inside the code area, while turning it off preserves horizontal scrolling.

Includes the coordinator lifetime fix from 0.62.1b1. For newly dispatched coordinators, the configured coordinator timeout measures inactivity; active work remains bounded by a separate maximum runtime, defaulting to one hour. Existing persisted jobs retain their original timeout policy. Worker and advisor timeout policies remain unchanged.

Retains shared Git comparisons, commit-aware questions, workflow commit history, and existing client compatibility. No additional data migration is introduced.

## Install and verify

Install the wheel in a new Python 3.11+ runtime using the existing private configuration. Preserve state and keep the previous runtime available for rollback. The signed Mac updater does not install companion packages.

Mac 0.63.1-beta.1 fixes the corresponding native viewer constraint. Compare long lines in unified and split layouts, enable Wrap, and narrow the code area.
