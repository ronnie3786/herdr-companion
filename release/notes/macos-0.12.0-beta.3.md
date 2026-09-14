# First Mate model controls

Choose the AI model and thinking effort directly above the First Mate chat
composer. Search the connected host's Pi models and save a separate choice for
each feature. Host default remains available.

Changes apply to the next First Mate turn. Running agents and worker defaults
keep their settings. Switching models preserves the feature conversation and
records the choice in its journal. Conflicting changes from another client ask
you to reload before saving.

Requires companion 0.12.0b3 or later for saving model settings and reading the
host model catalog. Older servers remain usable for chat and show an explicit
update-required message for these controls. The Mac updater only updates the
app; install the companion package separately. iOS remains compatible but this
release adds the picker to the Mac app only.

To test: open a live feature, click the model control above its message field,
choose a model and thinking effort, Save, then send a message. Provider access
is verified by Pi when that next turn runs. Automatic effort retains Pi's saved
session/default behavior; unsupported effort levels are adjusted by Pi.
