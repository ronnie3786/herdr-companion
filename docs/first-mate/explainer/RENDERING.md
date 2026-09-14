# Reproducing the First Mate reels

The three videos are edited sequences of actual native Mac UI captures using a
synthetic demonstration feature. They are not screen recordings of live model
executions. Chapter titles, letterboxing, small camera moves, and crossfades are
editorial treatments outside the app. No clicks or UI interactions are simulated.

Generate narration from `narration.json` and capture the native demonstration
states into an ignored input directory, normally `build/first-mate-media`:

- `one-conversation.wav`, `review-crew.wav`, `continuity.wav`
- `planning-light.png`, `implementation-light.png`, `checkpoint-light.png`
- `review-graph.png`, `review-agents.png`, `review-session.png`, `review-documents.png`
- `continuity-dark.png`, `handoff-history-dark.png`, `predecessor-dark.png`, `journal-dark.png`

Only use synthetic demonstration records. Do not capture production sessions,
project paths, API credentials, or private machine settings.

From the repository root, with Python 3 and FFmpeg installed:

```sh
python3 scripts/render-first-mate-reels.py
```

The script supports `--input`, `--output`, `--only`, `--font`, and `--bold-font`.
Its default fonts are Arial and Arial Bold from macOS. Other hosts can supply
equivalent installed font files. FFmpeg needs `libx264`, `drawtext`, `zoompan`,
`xfade`, and `loudnorm`. No Python packages or network requests are required.

Outputs are 1920 × 1200, 30 fps H.264 with AAC narration, English subtitle tracks,
standalone WebVTT captions, and JPEG posters extracted from each finished video.
Two-pass audio normalization targets −16 LUFS and −1.5 dBTP. AAC encoding can
slightly alter the measured true peak. The rendered files are decoded end to end
before verification is recorded under `build/first-mate-media/render-cache`.

Captions are timed to phrase boundaries in the supplied narration. If narration
is regenerated at another speaking speed, update `CUES` and scene timing in the
script. Caption text is checked against the complete source transcript before
rendering. Raw audio, captures, filter graphs, and intermediate clips remain in
the ignored build directory. Only the final videos, captions, and posters belong
in `media/`.
