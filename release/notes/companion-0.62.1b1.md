# Herdr Companion server 0.62.1b1

Corrects line wrapping in the shared web Git viewer's plain-text fallback. Wrap now keeps long lines inside the code area, while turning it off preserves horizontal scrolling.

Retains the shared Git comparison APIs, commit-aware questions, workflow commit history, and existing client compatibility from 0.62.0b1. No additional data migration is introduced.

## Install and verify

Install the wheel in a new Python 3.11+ runtime using the existing private configuration. Preserve state and keep the previous runtime available for rollback. The signed Mac updater does not install companion packages.

Mac 0.63.1-beta.1 fixes the corresponding native viewer constraint. Compare long lines in unified and split layouts, enable Wrap, and narrow the code area.
