# PR Review Assistant

Status: Implemented in macOS 0.27.0-beta.1 with companion 0.27.0b1 (2026-09-21); see
[pr-review.md](pr-review.md) for setup, behaviour, the CLI and the agent-control actions.
Originally a draft feature guideline (2026-09-20).

## Implementation notes

- Skill names confirmed on the development machine: `ios-review-remote-pr`,
  `comprehensive-pr-review`, `github-pr-explainer-video`, `github-pr-explainer-video-v2`,
  `tech-explainer-video`, `pr-explainer-dev-manager`, and the mark-viewed utility
  `mark-generated-and-test-viewed-in-pull-request` (`gh autoview`).
- Reviews run on the companion whose machine role is `development`; the Mac app resolves that
  machine (Settings → Machines → PR review host overrides it). Runs are panes in a dedicated
  PR Reviews workspace, one tab per review.
- Files from the review host reach the Mac through the companion's authenticated document
  endpoint and a local cache, the same pattern as agent result artifacts; no separate sync.
- Ask AI reuses the contextual assistant with a new `pr-review-question-v1` profile that keeps
  read-only tools inside the checkout so it can verify findings rather than repeat them.
- Delivered in one release: workspace and context library, ranking and the diff UI, Ask AI,
  and the CLI plus agent-control actions that Clicky can drive. Nothing is deleted; archiving is manual.


This is a guideline, not a spec. It captures the intent, the workflow behind it, and the
behavior we want. It is expected to change once implementation starts, and the implementation
session should feel free to adjust details as it learns what the code allows. Nothing here
prescribes architecture, file layout, APIs, or an order of delivery.

## Why this exists

When I am asked to review a PR (mostly iOS PRs), I already have a heavy, useful review
workflow built from skills and agents. The output of that workflow is scattered across
markdown files, an HTML report, audio summaries, and videos, and reading the actual diff
happens in a separate place (GitHub). The PR Review Assistant brings all of it into one place
inside the Herdr Mac app: the PR itself, everything the agents produced about it, and an AI
that can answer questions about the code with the full review as context.

The larger goal is a **code review assistant and tutor**: something that helps me understand
a PR, not only judge it, and that can answer random questions that come up mid-review, all
grounded in the context we already have.

## The review workflow this plugs into

Reviews are triggered when I am assigned or requested on a PR. Today I run some combination
of these skills:

- **iOS remote PR review.** Launches 5 to 8 dedicated agents, each reviewing from a different
  angle or specialty. Each writes its own markdown findings document. A final reviewer
  collects them, removes duplicates, and produces a consolidated list as an HTML artifact,
  with findings ranked (blockers, should fix, should not fix, minor, and so on). It also
  generates audio summaries so a human can move through the findings quickly.
- **Comprehensive code review.** A more holistic pass that looks for things the specialist
  agents do not, such as over-engineering patterns. I run it instead of, or in addition to,
  the iOS remote PR review depending on the PR. On a really large PR I run both.
- **Explainer video skills.** Generate explainer videos of the PR from different angles and
  in different styles. There are four: two GitHub PR explainers, a technical explainer, and
  a dev manager explainer. I use two or three of them regularly.

Everything those skills produce is context for a review, and the PR Review Assistant should
treat it that way.

## What it is

A dedicated **PR Review** section in the Herdr Mac app. It is its own feature, separate from
Active Work. (An earlier attempt at a workflow board inside Active Work never got debugged.
Keeping PR review as its own section is deliberate.)

Given a GitHub PR link, the app turns the PR into an AI-assisted, GitHub-style review
workspace. Around it sit the review context (documents, reports, videos), the record of which
skills and agents have run, and an AI that can be asked questions about the code.

## Feature areas

### 1. Starting a review

- I add a new code review by pasting a GitHub PR link.
- The app then asks which skills to run and shows me the list. I select the ones I want and
  the runs start.
- The runs execute on my **dev box** (see "Where reviews run").
- Long term, my own agents start reviews and run these skills without me. They fill in the
  documents, toggle the right selections, and link the files, so that when I open the review
  it is already prepared and I am presented with the finished result. The manual flow above
  should be designed so that this automation can take over the same steps.

### 2. Skills

- The skill list is built in and covers the skills described above:
  - Review skills: iOS remote PR review, comprehensive code review.
  - Explainer video skills: the four described above.
- The UI shows **which skills have been run** on a given PR.
- That state can be set **manually** in the UI and also **from the CLI**. The CLI path exists
  so agents can update it themselves as they finish work.
- **Custom skills.** I can add another skill to the list without updating the app, for
  example a brand new skill, or one I only want to test. It appears alongside the built-ins,
  can be selected when starting a review, and can be run manually. It can be added from the
  UI and from the CLI.
- The built-in skill names need to match what is actually installed on the dev box. The skills
  are not all installed on this Mac. Confirm the exact names before finalizing the list.

### 3. Where reviews run

- Review skills run on my **dev box**, not on the Mac I am sitting at.
- Which machine runs them is a **setting in the existing configuration**, not hardcoded in
  the app. If I later want reviews to run somewhere else, I change the setting.
- The dev box needs full GitHub access, mirroring what my work Mac has, so it can read the
  PRs I review.
- The repo already has a private config file with per-machine definitions and per-feature
  sections, and the apps already know which machine is the "Development" one. The PR Review
  setting should follow that existing pattern.

### 4. Workspace, history, and archiving

- All PR review agents run inside a **dedicated workspace** for PR reviews, so they stay out
  of my other work.
- Every review keeps its own record, so I can go back and look at old PR reviews later.
- I can have **multiple PR reviews going at the same time**, and each one stays separate.
- A per-review **agents section** shows which agents ran and what their sessions looked like.
- Finished reviews are **archived, never deleted**, and all of the data is preserved: agent
  sessions, findings, documents, links. Archived reviews remain findable but are out of the
  way of the reviews in progress.
- Archiving is **manual** for now. Automatic archiving (for example when a PR is merged or
  closed) is not part of this.

### 5. Review context library

Each review has a place to hold the context for that review.

- **Documents:** the per-agent markdown findings, the consolidated HTML report, the audio
  summaries, and any other files I add.
- **Drag and drop** for adding files, and possibly folders.
- **Explainer videos:** I can add a video, or at least a link to where it lives. It appears
  in the review UI as a shortcut that opens in the QuickTime player. The outputs of the four
  explainer skills land here.
- Context I add is available to the AI in the review (see "Asking AI about the code").
- The consolidated HTML report and the markdown findings should be viewable inside the
  review view, so I do not have to hunt for them.

### 6. The PR review UI

A GitHub-style PR review interface with AI built in.

**Marking files as viewed.**
- I can run a command or shell script that automatically hides certain files and marks them
  as read and viewed. We already have a skill that does this, and the UI should be able to
  trigger it.

**Impact ranking.**
- AI categorizes and ranks the files in the PR by impact:
  - **Low:** trivial changes, minor changes, syntax-only changes with little meaning.
  - **Medium:** somewhere in the middle.
  - **High:** APIs, critical data, logic, and similar.
- I can **filter to a single category** at a time.

**Guided view.**
- A second view style lists the files in the order AI thinks is best for building a mental
  model of the change, rather than in alphabetical or GitHub order.

### 7. Asking AI about the code (killer feature 1)

- Like the existing code review window, I can **select text and get an AI popup** to ask a
  question about it.
- The question sent to the AI includes, automatically:
  - The file, the line number, and the exact code snippet.
  - Which side of the diff the selection is on: the before code or the after code.
  - The context of the review currently in progress, including enough of the surrounding
    file to be useful (chosen sensibly, not the whole repo).
  - What the review agents have found, as a **reference only**.
- **Agent findings can be wrong.** The AI should treat them as one input, do its own
  research, and verify. When I ask it to dig deeper, that means investigating the code itself,
  not just re-reading or re-checking what the other agents concluded.

### 8. Clicky integration (killer feature 2)

Clicky (also called Learning Buddy) is my separate app with a visual cursor that can move
around the screen and click things, and that speaks to me using text-to-speech. I want it to
act as a guide and tutor inside the PR Review view.

- **Direction of control:** Clicky drives Herdr, not the other way around. Clicky is given
  the tools and knowledge to operate the PR Review view, essentially computer use pointed at
  this specific feature: it knows what pages exist, what to click, how to scroll, and what
  should be on screen.
- **How it drives:** Herdr provides a **rich CLI** (an MCP is possible if that turns out to
  fit better, but a CLI is preferred) and documentation. Through those, Clicky can drive the
  view, navigate and scroll, select files, pull context, and read the data it needs.
- The same CLI is what agents use to set review state (see "Skills"), so a single control
  surface serves both Clicky and my automation.
- **The experience:** I ask a question out loud, for example "how does the developer handle
  error handling if the network call fails to fetch this thing?" Clicky uses what it knows
  about the PR and the code to find the answer, replies in plain English ("the developer
  logs the error to the error logging app on this line, right here"), scrolls to the right
  file, and circles or points at the line.
- This is multi-step teaching, not a one-shot answer. It is the bigger of the two unlocks:
  a tutor that walks me through the code for whatever question comes up.
- The inverse (Herdr driving Clicky) was considered and is less preferred.

## Relationship to existing things

- **Active Work** stays as it is. PR Review is a separate section.
- **The existing code review window** is the model for the select-text-and-ask-AI behavior.
- **Contextual assistant work** already exists in the repo (`docs/contextual-assistant-architecture.md`)
  for other entry points. It is worth reading before designing the Q&A behavior.
- **Configuration and machines** already exist (`config.example.toml`, the fleet and machine
  definitions). The dev box setting should live there.

## Open questions

- **Getting dev box files to the Mac.** Review documents and videos are created on the dev
  box, but I need to open them on my Mac, for example a video in QuickTime. I believe the Mac
  app already has a mechanism for pulling files from my other machines, but this is not
  confirmed. Confirm it before building anything. If the mechanism exists, reuse it. If it
  does not, syncing files is a **follow-up** and is not part of the first pass.
- **Exact skill names.** The exact names of the four explainer video skills and the
  comprehensive code review skill are still to be confirmed against the dev box.
- **Order of delivery.** Nothing above decides what ships first. The implementation session
  should propose how to slice this: the review workspace and context library, the diff UI and
  ranking, the AI Q&A, and the Clicky integration are all substantial on their own.

## Terms

- **Dev box:** my development machine, configured as the "Development" machine in Herdr.
- **Review:** one PR being reviewed, with its own context, skills-run state, agents, and
  history.
- **Clicky / Learning Buddy:** my separate app with the on-screen cursor and text-to-speech.
