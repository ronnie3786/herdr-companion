# PR Review Agents

The review starts with people-like specialists, each with a name, avatar, review
prompt, and selected skill packages. The execution computer owns these private
profiles. A new installation includes one generic Comprehensive reviewer.

## Visual direction

Use the existing First Mate glass and haze surfaces, including their transparency
and accessibility fallbacks. The shared tokens provide charcoal `#151519`, primary
ink `#E9E9EC`, lavender `#AAA6F4`, avatar violet `#2A2244`, completed green
`#A3CBA7`, and working amber `#E4C386`. Use the app's scaled system type, with
semibold reviewer names, ordinary body instructions, and quieter status metadata.

The memorable element is the reviewer avatar, repeated from Settings through
selection and execution. Keep prompts, skill selection, and reports quiet and
left aligned. Checkmarks communicate selection independently of color. Group
headers select a whole team without hiding its members. Do not create a second
theme, a character builder, or decorative activity animations.

```text
Settings / Agent Roles             Start PR review
  First Mate roles                   Pull request link
  Custom roles                       [avatar] Comprehensive       [check]
  > PR Review Agents                 Team name                    [check]
      Comprehensive                  [avatar] Specialist          [check]
      New review agent               [avatar] Specialist          [check]
                                     Add only        Start review

Review / Agents
  Review team                                     Add agents
  [avatar / name / running]   [avatar / name / completed]
  [consolidator / waiting for reviewers / latest report]
  Run history and event details
```

This deliberately follows the requested First Mate visual language. Avatar
identity, reviewer selection, and a visibly separate consolidation step carry the
hierarchy; the design does not need extra color systems or equally weighted
cards for every metadata field.

## Observable requirements

- A collapsed PR Review Agents section in Settings supports custom names,
  avatars, optional team names, review prompts, and the existing Mac skill picker
  and package copying flow. It omits First Mate routing and delegation controls.
- A blank prompt stays blank in storage. The faded preview demonstrates the
  actual adversarial review fallback and injected pull request URL.
- Only Comprehensive is bundled. Operator-specific specialists and teams stay
  in private configuration, never in repository defaults or screenshots.
- Starting a review selects saved agents with checkmarks and team selection.
  Profiles use the execution computer's default model.
- Each selected agent gets a distinct run and attributable raw report. The
  interface shows queued, running, completed, failed, and ended states honestly.
- A consolidator waits for the chosen runs, checks and deduplicates findings,
  and produces a report with links to the raw reports. Failed or missing reviews
  remain visible as incomplete coverage.
- Adding agents or rerunning reviewers triggers fresh consolidation. A stale
  consolidation never replaces a report for newer runs or changed PR commits.
- Existing review history and older clients remain readable. New functionality
  is advertised explicitly and unavailable on an older companion.

## Verification

Use synthetic profiles and reviews for native renders and contract tests. Cover
profile persistence and skill restrictions, blank-prompt fallback, batch launch,
restart recovery, failed reviewers, reruns, changed commit SHAs, and competing
consolidations. Verify selection and host changes cannot apply stale results.
Inspect native screenshots with normal and large type and glass disabled.
