# Herdr Companion 0.58.0-beta.1

PR Review now has a coding buddy. Open a prepared review's Files tab and choose
**Start walkthrough** for short chapters that teach what to inspect and why.
You control **Next**. Ask a question at any point, follow the relevant code, then
use **Back to walkthrough** to return to your saved position paused.

The compact dock expands into explanations, chapter navigation, saved questions,
and original review excerpts. Sources distinguish available reviewer attribution,
revision freshness, and the buddy's separate code assessment. Existing review
skills are reused and are not rerun by starting a walkthrough.

Listen with the configured Kokoro voice. Circles, underlines, and arrows follow
spoken phrases on exact diff lines. Pausing, seeking, replaying, and changing
speed keep drawings synchronized. Voice questions use the existing recorder and
transcription service; the transcript stays editable before sending.

Install companion **0.58.0b1** separately on the review host for the new guide and
context APIs. Captioned narration requires the existing private Kokoro service
configuration. Older servers keep the original PR review workbench. The Mac
updater installs only the Mac app; this release does not install an iOS build.

Text remains available when audio or a drawing target cannot be used. A changed
PR revision pauses old guidance until you start a new walkthrough. Completing a
walkthrough does not mark files viewed or submit a GitHub review.
