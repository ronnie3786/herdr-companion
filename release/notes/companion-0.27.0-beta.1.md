# Companion 0.27.0 Preview 1

## PR Review

- Adds the `pr-review-v1` capability and the `/api/v1/pr-reviews` API: reviews keyed by GitHub pull request link, per-review checkouts under the state directory, parsed diffs, AI impact ranking and guided order, viewed-state sync with GitHub, a document library (findings, reports, audio, video, links), skill runs launched as panes in a dedicated **PR Reviews** Herdr workspace on the review host, and an append-only event log. Reviews are archived, never deleted.
- Adds the `pr-review-question-v1` question profile: the same contextual question contract as `contextual-question-v1`, but the Pi run starts in the review's checkout with read-only tools (`read`, `grep`, `find`, `ls`) and a charter that treats agent findings as reference only. Scoping is working directory plus charter, not a sandbox.
- Installs the `herdr-pr-review` JSON CLI next to the existing commands so agents and Clicky can create reviews, start and finish runs, mark skills, set rankings and viewed state, add documents and links, archive, and open a review at a file and line. `herdr-control ui segment pr-review` and the `pr-review.*` UI actions drive the Mac view.
- New private configuration table `[pr_review]` (workspace label, checkout root, runner, model, auto-rank, viewed sync). All keys are optional; see `config.example.toml` and `docs/pr-review.md`.

## Matching components and safe update

Use companion **0.27.0b1** with macOS **0.27.0-beta.1** for PR Review. Install it on the machine whose configured role is `development` (the review host) and on any companion the Mac uses to reach it; `gh` must be authenticated there and the review skills installed. The signed Mac updater does not install this package, update its bundled CLIs or Pi extension, switch services, or restart a companion.

Follow the documented [server update procedure](https://github.com/ronnie3786/herdr-companion/blob/companion-v0.27.0-beta.1/herdr_harness/README.md#update-the-server): install the wheel into a fresh runtime, validate the private configuration with the new interpreter, switch the service, then confirm `GET /api/v1` advertises `pr-review-v1`.
