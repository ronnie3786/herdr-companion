# Herdr Companion

Native Mac and iPhone apps, a web client, and one standalone companion server
for [Herdr](https://herdr.dev). Follow terminal sessions, chat with Pi agents,
manage notes and Active Work, review changes, and receive agent results.

The companion server owns its API, authentication, event streams, local tools,
attachments, and state. Install the upstream Herdr terminal separately. Git,
Pi, and optional integrations are ordinary external tools; no other dashboard
or orchestration repository is required.

## What Herdr can do today

Herdr is an experimental personal tool under active development. Expect rough
edges and changing workflows. This is a running feature list, not a promise that
every client supports every feature or that all integrations work without setup.

| Feature | What it does |
| --- | --- |
| Multiple computers | Save your computers in one private configuration and switch between their workspaces and sessions. Connection credentials stay in Keychain in the native apps. On Mac, optional per-machine `sidebar_label` and `sidebar_order` values configure the one-to-three-computer segment titles and partial order without changing machine identity or the saved selection. Missing labels use full names; names and roles imply nothing. The first saved companion serves the authoritative private roster on connection or Refresh and identifies its own configured record even when the saved connection uses localhost or another origin alias; other paired computers still require unique exact-origin matches. Runtime updates require matching companion and Mac versions. Zero machines remain hidden and four or more keep the full-name menu. |
| Mac, iPhone, and browser clients | Follow work from a native desktop app, your phone, or a browser connected to your companion server. The clients have different capabilities. |
| Native iPhone and iPad conversations | **Agents** groups currently available Pi sessions by workspace, with a prominent workspace heading, small machine label, tab sections, and compact agent cards with full wrapping titles, a single status/activity row, and short ages. Workspace and machine labels share a row when space allows; large text and long names expand naturally. Generic Pi labels appear once in the list summary. Workspaces and tabs are ordered by their newest matching chat, with newest-first agents inside each tab. Search these fields and tap a card to open its session. Long-press for Rename, Smart Rename, star, tab color, workspace navigation, copy pane ID, Mac controls, and confirmed close actions. Smart Rename uses a separate read-only run and preserves newer manual edits. Offline machines show the last known status. No server update is needed. The mobile navigator defaults to a flat newest-20 **Recents** list; choose **All** for Unread, then Starred, then machine → workspace → tab → pane. Search, machine, range, and optional tab-color filters intersect. Six tab-owned colors and editable labels persist only in that iOS app sandbox; Mac assignments are neither imported nor synchronized. Pane screens use charcoal chrome with system-scaled prose and Chat/Git/Terminal/Skills in Pane actions. Chat uses a one-line inline title and the full conversation width without a decorative turn rail, duplicated agent/status card, or breadcrumb. Pane actions owns star and the honest **Chat history → Last prompt** shortcut; pushed panes retain native Back/swipe while root and split-detail panes expose the Chat navigator, replacing rather than duplicating the system split-column control. Model and Thinking are small leading text pickers with adjacent down chevrons and 44-point tap targets; Listen and TL;DR are trailing icon-only actions. Common values share one compact row; long model names truncate within their budget, and accessibility text stacks safely. They retain live Pi capabilities and playback state without decorative button chrome, and require no server update. The unified input card shows selected attachments with upload status and photo previews; terminal keys stay hidden until requested from More. Unsent text drafts remain in memory per pane while the app runs; they are not persisted or synced, and the legacy Pi bridge may still trim surrounding whitespace on submission. |
| First Mate stability and recovery on Mac | A scheduler guardian and persistent hourly sweep detect stale work, assess legitimate waits, nudge stuck workers, and safely continue verified-stopped assignments. Source recovery archives, durable effect receipts, successor acknowledgement, retry limits, and handoff-churn detection prevent blind restart loops. Human stage gates remain intact. Open **First Mate → Workflow → Stability & recovery** for progress, interventions, checkpoints, and archive references. Requires the matching server/Pi package with `first-mate-reliability-v1`; older components remain compatible but lack these protections. See [behavior, configuration, and limits](docs/first-mate/reliability.md). |
| First Mate saved sessions on Mac | Open an Agent Session from Overview, Agents, workflow evidence, or session history to peek at its saved Pi conversation: prompts are right-aligned bubbles, agent replies render as Markdown, and text-only tool results expand on demand. No composer or session controls appear; older text-only responses remain readable. Session details hold model and usage metadata; Load earlier messages keeps the exact session and chronological order. The existing First Mate session API is sufficient; no server update is needed. |
| First Mate Chat on Mac | First Mate and Chat use the same prompt composer: multiline editing, file uploads and drag-and-drop, voice notes and dictation, fenced-code paste, and previewable quote chips. Select text in a recent completed First Mate reply to **Quote & comment…**, or copy a reply or code block using Chat's shared controls. Drafts, files, and quotes stay with their feature on this Mac while the app runs. Model and thinking choices use the shared picker; changes to an existing coordinator session require an idle boundary and explicit confirmation of possible context reprocessing and cache costs. **Coordinator context** shows the coordinator's latest measured tokens, window, and managed-handoff threshold—not cumulative worker usage. First Mate checkpoints and continues in a fresh session near that threshold; ordinary Pi compaction is intentionally unavailable. File uploads, context telemetry, and server-enforced model-change safety require the matching companion with `first-mate-attachments-v1`, `first-mate-context-v1`, and `first-mate-safe-model-settings-v1`; older servers keep text chat and show upgrade guidance. See [First Mate Chat parity](docs/first-mate/chat-parity.md). |
| First Mate on iPhone and iPad | One conversation per feature, with a workflow timeline/graph, step-linked agents and documents, and exact saved Pi sessions including handoff history. Archive finished or irrelevant features without changing workflow status or deleting their records; Show Archived makes them available to inspect or unarchive. iPhone uses focused sheets; iPad adds a feature sidebar and inspector. Supports system/light/dark appearance and scalable text. Uses the same First Mate state and authenticated API as Mac; archive controls require `first-mate-archive-v1` from the matching companion server. See [mobile behavior and verification](docs/first-mate/ios.md). |
| First Mate attention badge on Mac | In the Mac Chat sidebar, **First Mate** shows an orange count badge whenever any configured companion host has a feature waiting on your direction (`awaiting_direction`) or an intervention after recovery was exhausted (`blocked`). The count is global and appears before First Mate is opened: the Chat search, machine, color, and recency filters and the selected First Mate host never change it, and each host-owned feature counts once. It refreshes with the same ten-second fleet poll, hides at zero, caps the visible number at **99+** while accessibility and hover text keep the exact total, and does not clear just because First Mate was opened. A host that is temporarily unreachable keeps its last reported status instead of dropping the reminder, even while other machines are renamed, reordered, or edited; only removing or reconfiguring that host clears its contribution. Uses the existing `first-mate-v1` responses on every configured host; no server update is needed. |
| First Mate Git on Mac | Switch a selected feature between **Chat** and a full-width **Git** workbench without losing its conversation draft or workflow selection. Inspect the project checkout or choose an exact recorded assignment worktree, then view diffs and history, stage or unstage files, and open or reveal local files. Pop out a machine/feature/workspace target into its own pinned window. Native feature refreshes, transient terminal reconnects, and Git-workspace refreshes keep the open workbench visible rather than repeatedly showing “Reading working tree…”. Git document identity uses the actual connection and route values, not JSON key ordering; this Mac fix needs no server update. Requires a matching companion advertising `first-mate-git-v1`; a live terminal pane is not required, while older or API-unreachable hosts and removed worktrees remain explicit unavailable states. See [First Mate Git](docs/first-mate/git.md). |
| First Mate model usage and cost | See Pi-reported estimated USD cost beside each task's ticket label, with model and token breakdowns in Overview, Agents, and saved session history. Task totals include all retained managed coordinator sessions, nested workers, retries, handoffs, and advisor/recovery sessions, counted once even when the visible history is truncated. Agent subtotals distinguish their own sessions from their full child tree. Missing or incomplete usage is labeled, never silently shown as zero; subscription providers may explicitly report zero. Requires companion **0.30.0b1** or newer with `first-mate-usage-v1`; older servers remain compatible but cannot supply usage. The Mac updater does not install the separate server package. Arbitrary unregistered sessions and external-service charges are not included. |
| First Mate architect profile | Plain-English architecture and design reviews, architect audits, and implementation second opinions use an independent host-pinned architect model without changing ordinary planner, worker, or coordinator routing. Configure `architect_model` and `architect_thinking` in each machine's private `[first_mate]` settings; there is no Pi-default fallback, and the Mac host-routing view reports **NOT CONFIGURED** until a pin exists. Assignment and saved-session details keep requested policy separate from Pi-observed actual model evidence. Requires companion **0.34.0b1** and the First Mate Pi extension bundled in that server package on each host; the Mac updater does not install the server package. Older companions that omit architect routing remain compatible. |
| Terminal sessions | Browse workspaces and panes, see terminal output, and send input to a running upstream Herdr terminal session. On Mac, right-click a controllable shell pane and choose **Smart Rename** to name it from its recent terminal output and available pane metadata through the same tool-free naming run, naming preferences, and strict execution-machine selection rules as pane, HUD, and color-group naming. |
| Comfortable reading on Mac | A charcoal and lavender interface with 15-point system-font conversation text at the default scale in Chat and the HUD, bounded reading width, and Quiet chrome navigation. The prompt keeps labeled Attach, Paste code, and Voice actions close at hand, with Terminal keys above the input. Paste code appends a fenced clipboard block at the end of the draft; Command-Shift-V does the same while a Chat or HUD prompt is focused. Both routes preserve native undo and target their own composer even after a focus change. Long drafts scroll with the mouse or trackpad after five visible lines. Shift-, Option-, and Command-Return are handled before SwiftUI key dispatch in both chat and HUD editors, inserting a newline at the caret without sending and preserving undo/redo. Terminal follow re-anchors after viewport resizing and mode switches. Command cards show a three-line preview, the full command on expansion, and available structured input and partial output while running. In main Mac and iPhone chats, tool groups are labeled Clanking, start collapsed, never expand themselves for failures, and preserve the reader’s chosen disclosure state as updates arrive. Failed counts remain visible in red while the group border, chevron, icon, title, total count, and latest tool title keep their neutral styling. Appearance follows the app text-size preference. No server update is needed. |
| Pi agent conversations | Chat with Pi agents, follow their replies and tool activity, attach files in a compact, horizontally scrolling strip, and choose available models and reasoning settings. On Mac, the chat header shows the machine. Use the star beside its title to add or remove the chat from Starred. Click its title to edit inline (Enter or focus loss saves, Escape cancels). Right-click a sidebar chat or chat header and choose Smart Rename for a contextual title using a separate quick AI run with your **Settings → Agents → Smart Rename** model and thinking level. On Mac, a successfully submitted prompt is enough; naming does not wait for an assistant reply, and it can instead read a bounded terminal-output window or pane/workspace metadata for a shell pane, treating that context as untrusted data. Each rename resolves and runs on the machine that owns the target; a saved model the companion does not offer, a companion default missing from its own catalog, a non-reasoning model paired with an effort above Off, or an unreadable or empty catalog stops the rename, keeps the current title, leaves the stored model and thinking choices unchanged, and reports an actionable error naming the selection and companion instead of substituting another model or machine. Model catalogs list what a companion's Pi installation offers — they are not proof of provider credentials or service health, and the provider must work in that companion's environment. Requires the existing headless agent, Pi snapshot, terminal-output, and agent-model APIs and a companion that advertises the tool-free `smart-rename-v1` naming profile; no conversation is created, and an older companion reports that its server must be updated instead of receiving a naming request. You can also use the pane actions menu, or right-click a sidebar chat, HUD session, or chat header to copy its workspace pane ID. The pane actions menu groups view, control, Pi session, and pane actions. Compact Chat and Reload Pi extensions (`/reload`) live in the prompt's … More popover. Requires Pi and its configured providers. |
| Agent awareness and offline references | Managed pane chats, saved HUD chats, ordinary Companion agent runs, and validated First Mate roles receive a compact identity and pointers to installed, on-demand guides—never the guide bodies. External Pi and restricted question/naming/brief profiles stay unchanged. Agents can run `herdr-docs list` or `herdr-docs read overview` without configuration or network, then consult installed CLI help and live catalogs before claiming capabilities. See [coverage and rollout](docs/agent-awareness.md). |
| Close chats without losing tabs | On Mac and iPhone, **End Pi & close pane** keeps the tab and workspace. For the tab's last pane, the server verifies a fresh shell in the same folder before quitting Pi and closing the old pane. Companion shows **No open chats → New Pi chat / Open shell**, reusing that reserved shell without carrying over the old chat's title or transcript. Saved conversations are not deleted. Requires the updated server and native app; older servers show an upgrade message instead of falling back to destructive close. Ordinary Close pane and upstream Herdr close remain unchanged. See [behavior, safety limits, and verification](docs/keeping-tabs-open.md). |
| Clickable pane references on Mac | Agent replies in Chat, saved HUD chats, and the Agent window recognize valid pane IDs such as `w3:p9`, machine-scoped IDs, and supported Herdr deep links. Click to open that pane inside Companion; HUD links open the main window. Bare IDs stay on the response's machine. Validation uses the latest connected fleet snapshot, and clicks recheck the target terminal. Missing/ambiguous references remain plain text; fenced code and user prompts are not auto-linked. No server update is needed. See [link behavior](docs/response-pane-links.md). |
| Pi session families | The Mac sidebar nests spawned Pi sessions beneath their parents, with collapsible children and workspace labels for work in another workspace on the same machine. Install the matching companion and Pi package; see the [Pi upgrade instructions](pi-semantic-bridge/README.md#upgrade-running-pi-sessions) for existing sessions. |
| Contextual questions | Ask about selected Git code, the current Herdr pane from the Mac HUD, or a note. Inspect and add context, resume questions, and explicitly continue in an agent for actions. Requires a companion with `contextual-question-v1`; the initial question profile uses supplied context with all tools disabled. |
| Saved HUD chats | On iPhone and iPad, open **Agents → HUD Chats** to search, read, continue, or create the same saved conversations available in the Mac HUD's **Chat history**. Choose the machine that owns the chat; accepted turns and status sync through its companion, and visible chats refresh without resubmitting prompts. Leaving the screen never deletes or stops a saved run. New chats default to the selected machine’s home folder (`~`). Use the HUD folder menu → **Manage folders…** to add or remove custom absolute paths saved separately for each machine on this Mac, then choose a path before sending. Existing chats keep their original folder across clients. Custom-folder submission now reaches and validates the path on the target server; it requires the updated companion advertising `hudChatWorkingDirectory`, and older servers show an upgrade message instead of rejecting an unexplained request. Remote paths are sent unchanged; custom-folder shortcuts and unsent drafts remain local. Sending from the Mac HUD creates an independent **HUD chat** bubble beneath the orb and immediately frees the composer for another one-off. Each chat keeps its own transcript, draft, attachments, running state, and explicit workspace handoff. Completed unread replies glow green and say **Ready**, without auto-opening. Click a bubble to expand its chat; **New chat** or the orb returns to the separate fresh composer. The clock button opens searchable **Chat history** even while other chats run, reusing an already-open conversation. **Remove from HUD** hides a finished bubble without deleting server history. Bubbles and unread state survive relaunch; saved active runs reconnect without resubmitting. Saved-chat browsing and home-folder conversations use existing `hud-chat-v1` support; the custom-folder fix requires a separate companion server update, not just an app update. **New chat** saves rather than deletes the conversation. Chats and their Pi sessions remain indefinitely in private server storage, outside terminal workspaces; **Continue in agent** explicitly promotes the full conversation. Agents can find them with `herdr-hud-chats list`, `search <text>`, and `show <agr_ID>`; with a companion that advertises `chat-tab-colors-v1` and an opted-in publisher, `--scope terminal` on list/search adds terminal chats with read-only tab color and label filters and grouping without changing saved-history behavior. HUD chats use normal Pi tools, skills, extensions, and project context, subject to existing Pi project trust settings—not a read-only or Herdr-sandboxed profile. Requires the updated companion server, CLI, and Pi package; older servers show an upgrade message before new HUD submissions. Contextual note/code questions keep their separate restricted profile. See [HUD history](docs/hud-chat-history.md). |
| Resizable HUD chats | Drag **Resize** at the expanded chat’s lower-left corner to adjust width and height; right-click for Larger, Smaller, or Reset chat size. The size is remembered on this Mac and shared by its HUD chats, with screen and notes/voice space limits. **End Chat** beside the task status confirms before stopping that HUD run and closing its bubble. Saved history remains searchable; unsent drafts are discarded. A failed stop keeps the chat open for retry, and promoted workspace sessions are never closed. No server update is needed beyond existing HUD chat support. |
| Floating Mac assistant | Use a compact floating panel to send prompts and follow agent progress and results without keeping the main window in front. Press left and right Command together to capture the frontmost app window and add its PNG to the separate **New chat** composer. Herdr detects the two Command keys independently from two permission-free signals, shows a notice on the HUD for every capture, and notifies when the HUD was hidden; ⌃⌥C and File → Capture Frontmost Window do the same thing without any keyboard permission, and Settings → HUD → App Shots shows a live key readout plus the last trigger and outcome. Any unsent text, attachments, machine, and folder stay in place, and nothing is sent automatically. Screen Recording permission is required; Accessibility never is, and Input Monitoring is optional. A drag straight out of the system screenshot preview now lands in the HUD too. See [App Shots: window capture](docs/dual-command-screenshot.md). Hover the orb and click its top-left compact control—which visibly indicates when enabled—to collapse immediately to a centered 20-point status signal; hover the signal to preview the collapsed HUD, or turn the control off to keep the standard HUD visible. This mode needs no server update. Choose the model and thinking level directly above the HUD prompt; thinking changes persist to HUD Settings and apply to the next prompt, including thread replies. The chat header omits New note and Ask actions; notes remain available in the note stack and File menu. The chat card uses soft, low-opacity shadows. Settings → HUD → Visible agents defaults to 4, with additional agents grouped under a compact circular +N. Choose 1–20 or Show all for an uncapped, scrollable list; clicking +N temporarily reveals every agent. No server update is needed. Session notification bubbles use natural one- or two-line title heights, with measured panel and scroll budgets. Finished notifications use the green signal outline on both the bubble and orb, while red remains reserved for blocked or failed work; the orb’s numerical attention count is announced to accessibility tools instead of being drawn over the icon. Finished and idle-result session bubbles show their workspace name instead of the previous activity, while running bubbles retain live activity; hidden-title mode also hides workspace names. The model name and cumulative Pi cost alternate together across all bubbles with a gentle fade every five seconds beside the status; metadata refreshes every 15 seconds. New and revealed bubbles join the shared phase immediately. A missing value is not substituted with invented metadata. Audio controls sit at the top right. Updated companions allow headless runs for one hour by default; existing timeout overrides remain effective. Set `HERDR_HARNESS_AGENT_TIMEOUT_SECONDS` in the private configuration's `[environment]` table for a limit from 1 to 86,400 seconds. |
| Chat quotes and session chapters on Mac | Native selection keeps text wrapping and row heights aligned during window resizing and streaming. Select text or code in any of the last three completed, text-bearing agent messages, choose **Quote & comment…**, and Save a previewable quote chip. Interleaved tools and empty messages do not consume quote slots. User messages, replies outside that window, and historical chapters remain copyable but do not offer quoting. Quotes and their comments are sent inline under **Quoted response segments:**, not as file paths. Save never sends. New Pi chat shows progress, confirms the changed session, and keeps the previous transcript above a visible divider with its copyable closed-session ID—even while the new session is empty. Local history survives relaunch without feeding old context to the new agent. See [interaction details and limits](docs/mac-chat-quotes.md). No server update is needed. |
| Conversation context on Mac | Drag a Pi chat from the sidebar onto another prompt on the same machine, or right-click it and choose **Add to current prompt**, to add a removable context chip pinned to the source Herdr workspace ID and current Pi session ID. No transcript is fetched or embedded by the Mac app. The sent prompt gives the receiving agent the exact `herdr-session-context get` command and explicitly treats fetched context as prior conversation data, never as instructions that override the current request. Cross-machine references are unavailable. Each prompt keeps its own staged references while the Mac app runs. Requires the matching companion 0.16.1b1 with `pi-session-context-v1` and the installed `herdr-session-context` CLI. |
| Experimental concise response briefs on Mac | Opt individual Pi chats into an additional, restricted model request for completed answers, including very short ones. The native rail shows one direct takeaway, at most one necessary caveat, and up to two short links to exact local source slices. An app-wide **Length** choice—Minimal (1×), Medium (2×), or Long (3×)—caps total visible words/scalars at 40/240, 80/480, and 120/720; for multiplier `m` the exact ceilings are `m × max(40, min(240, floor(readable characters ÷ 4)))` scalars and `m ×` the existing word ceiling, and a short source's allowance is a maximum, never a minimum or a padding target. Changing the preset applies to every chat and regenerates the source selected in the rail (or the latest completed answer) after accepted work reconciles; re-selecting the same value does nothing, and no minimum output length is ever imposed. Model and thinking stay independent. Requires `response-brief-v1` plus the additive `responseBriefs.lengthPolicyVersion` 2 capability with all three options; legacy receipts still replay exactly, an older server shows an upgrade notice instead of silently ignoring the setting, there is no generic-agent fallback, and the Mac updater does not install companion server packages. An unmatched saved baseline shows a warning with confirmed latest-only recovery, never hidden history backfill. See [setup, privacy, limits, and verification](docs/response-briefs.md). |
| Notes | Notes use ink-colored cursors and title placeholders, with title/body defaults another point larger. The note-card header no longer includes New note; creation remains in the note stack and File menu. Use the labeled **Actions** menu for **Ask about this note**, **Tidy with AI**, and **Take action**; busy-state guards remain in place. Create notes from the Mac HUD note stack or File → New Note (Shift-Command-N), including when no notes exist. On the collapsed Mac HUD, hover over the HUD to reveal Notes at the orb's bottom-left corner, mirrored against Mic at bottom-right, and X at top-right. All three controls are 20% smaller and hidden at rest. Click Notes to expand or minimize the list; the expanded chat retains its Notes toggle below the card. Capture ideas in resizable note cards, edit their title and text on iPhone, and use them as context for agents. iPhone saves sync through the companion and detect conflicting edits. |
| PR Review on Mac | Open **PR Review** from the left navigator under First Mate (⌘8) and paste a GitHub pull request link. The review is prepared on the machine whose role is `development`: the companion fetches the PR with `gh`, checks it out into its own worktree, parses the diff, opens a tab in a dedicated **PR Reviews** Herdr workspace, and runs the review, explainer-video and utility skills you choose. Files are ranked by AI impact with a single-category filter, a **Hide viewed** toggle and a **Guided** reading order; PR Review, Chat Git, and First Mate Git use one shared syntax-highlighted code renderer with roomier line spacing, red/green rows, gutters, and changed-word emphasis. A short **Why** explanation for the impact rating is visible above each diff, and empty filters keep their controls at the top. **Ask AI** is available on any selection, sending the file, side, lines, surrounding code and the agents' findings (reference only) to a read-only question profile that verifies against the checkout. A context library holds findings, HTML reports, audio, videos, links and dropped files; Agents and Skills tabs show every run and let you mark skills ran or not run, or add custom skills. Right-click an active review row (selected or not) or the open review's header to **Pop Out into Window**: that review opens in its own resizable window pinned to the same host, so it stays visible while the main window keeps navigating other chats; reopening focuses the existing window, closing is presentation-only, and every active review can have its own window. Reviews are archived, never deleted. The `herdr-pr-review` CLI and `pr-review.*` agent-control actions let agents and tutors drive the same workspace. Requires companion 0.27.0b1 advertising `pr-review-v1` on the review host; older servers show an update message. New Ask AI questions stay in **Saved questions** bubbles below the diff and can be reopened after navigation or relaunch; they remain local to this Mac, pinned to the original host, file and revision. Pop-outs, saved bubbles and bundled PR diff rendering need no server support beyond `pr-review-v1`. Companion **0.40.0b1**, installed separately on the review host, adds short-by-default answer instructions and refresh recovery that retains the last usable review, handles rebased heads, and prevents optional viewed sync from breaking review preparation. See [PR Review](docs/pr-review.md). |
| Active Work board | Start from a template, then edit each ticket's path with review loops and extra steps. See the current action, owner, checkpoints, visit history, and agent handoff. Return to linked sessions. See [ticket paths](docs/ticket-paths.md) for board and agent controls. |
| Recent chats on Mac | Choose Recents from the sidebar clock menu for roomier rows (10 extra points between chats), single-line titles with quiet machine/workspace context and explicit Working, Done, or attention status. The secondary line is 1 point larger, with the project/workspace name in bold. Hover for full tab context or right-click to open the workspace. Sidebar titles and statuses observe live panes, including Smart Rename and completion updates. Selected chats use a background highlight without a leading stripe. Other sidebar categories keep compact labels without the Recents subtitle when switching filters. Requires no server update. |
| Tab colors on Mac | Right-click a tab, sidebar chat (including Recents), workspace chat card, or chat header → **Tab color** to assign or remove one of six muted accents: Lavender, Iris, Rose, Clay, Sage, and Slate. Every chat in the tab inherits the color, including future panes; only the left sidebar's chat rows and color key are tinted. The main chat, header, composer, and workspace cards retain their normal backgrounds. Active colors appear between **Filter chats** and **New session**. Click a color label to filter all sidebar categories to that color, intersecting the search, machine, and recency filters; click it again or **Show all colors** to clear. Color-key rows are 50.4 points tall (10% shorter) with 14-point titles that follow the app text-size setting. Use the pencil for inline label editing: the label is focused and selected immediately, ready to type (Enter or click away saves; Escape cancels), or right-click → **Smart Rename** to prefer a Jira key/title present in the grouped conversations. Shortcut labels use one or at most two lines. Right-click a color shortcut → **New chat** to create a chat in a tab with that color; when several tabs share it, choose the destination. Smart Rename uses the same **Settings → Agents → Smart Rename** model and thinking level as pane, HUD, and terminal-pane naming, executes on the machine of the first successfully sampled controllable pane, and can build context from a bounded terminal-output window or pane metadata when no Pi conversation is readable; a saved selection that machine does not offer fails without renaming and reports the selection, while **Off** and other valid levels pass through unchanged. It uses supplied context rather than querying Jira. Color labels are shared by tabs using the same color and persist locally on this Mac, not across clients; pane titles renamed through the companion are server state visible to every client. Smart Rename requires the companion to advertise its tool-free naming profile; the other tab-color features need no server update. Assignments and labels never synchronize back from a companion; the separate, default-off **Share tab colors with companions** setting in Settings → Privacy publishes each known tab's color and effective label as a read-only copy to the configured companions so agents can list and group chats with `herdr-control find` and `herdr-hud-chats --scope terminal`. Local storage stays authoritative, other clients never import this Mac's values, agents cannot change them, and sharing requires updated companion server and CLI packages, which the Mac updater does not install. See [tab color discovery](docs/chat-tab-colors.md). |
| Activity and attention | Sending a Pi prompt and starting new activity are silent on Mac; completion and attention feedback remain available. See recent activity and identify sessions that need attention. On Mac, right-click a sidebar chat and choose **Mark Unread** for a persistent local green-check reminder. Opening or interacting with the chat clears it; **Mark Read** clears it manually. This does not change the agent’s real status, send alerts, or restore a HUD notification bubble. No server update is needed. |
| Sidebar creation | Workspace folders are easier to scan: 14-point semibold labels in the brighter text color, 14-point folder icons, and taller rows, so folders stand out from the tabs and chats nested inside them. The change follows the app text-size preference, keeps long names tail-truncated with their counts and tooltips, and is Mac-only with no server update or new setting. Use the labeled New workspace action, or hover a machine row and click its folder-plus button to create directly on that machine. Right-click a workspace heading—including Unread and Starred groups—for New tab. Creation requires a controllable machine. |
| Navigation history | Back and Forward include switches between Chat and Git on the same pane, as well as other segment destinations. |
| Agent-driven Mac control | The authenticated `herdr-control` CLI searches configured machines, resolves exact workspace/tab/chat identities, opens them in an enabled Mac receiver, switches main segments, and invokes cataloged UI/resource actions with receipts. Tab colors are read-only: `find chats` and `find tabs` can filter and group by color, effective label, or publisher installation, and the former `chat.tab-color` mutation is disabled in both the relay catalog and the Mac receiver. Enable **Allow agent control** once in Mac Settings; authorized CLI actions need no second UI confirmation. Requires the matching companion/CLI and Mac app with `agent-control-v1`. Historical search and nested-menu coverage are explicitly bounded, not complete app-wide parity. See [setup, commands, and limits](docs/agent-control.md). |
| Git changes | Inspect repository changes and diffs from a workspace. Chat Git, First Mate Git and PR Review share their code renderer and theme, with syntax colors, roomier lines, and prominent red/green line, gutter, and changed-text backgrounds. File rows prioritize the complete filename with a left-truncated directory hint and full-path hover tooltip. These Mac presentation changes need no server update; browser file rows require updated web assets. Requires Git and the built web assets for the Mac Git view. |
| Files and skills | Search workspace files, attach context, and browse available agent skills. |
| Agent results | View returned files and other result attachments alongside agent responses. Mac Chat hides orphaned attachments whose original response is absent, instead of showing an “Other session attachments” section; associated cards and stored artifacts are unchanged. |
| Voice input and spoken replies | Dictate prompts or notes and listen to responses when compatible transcription and speech services are configured. |
| GitHub and Jira context | Bring review requests and tickets into your workflow using your own authenticated GitHub and Jira command-line tools. |
| Agent profiles | Edit **SOUL.md** personality and **USER.md** preferences in Mac Settings or Fleet. Assign a machine-local or explicitly shared profile, add machine-specific preferences, inspect sync status, restore revisions, and review agent-proposed edits. Personal and work profiles stay separate unless explicitly shared. The execution host, not the viewing client, selects the profile; active conversations/assignments keep a pinned snapshot. Requires matching companion, Mac, CLI and Pi updates. See [profiles, sync, privacy, and adoption boundaries](docs/agent-profiles.md). |
| Fleet management | Manage configured skill catalogs and destinations across your computers. Requires a trusted catalog and local configuration. |
| Workspace cleanup | Preview suggested cleanup decisions and inspect what will be affected before applying them. |
| Notifications and app links | Receive configured push notifications and open supported destinations in the iPhone app. Requires your own Apple push and domain setup. |
| Mac app updates | Check a signed GitHub Releases feed, see an update banner, and choose to install and relaunch. Includes an optional preview channel. Existing custom installations need a one-time setup; see the update guide below. |
| Report bugs and request features from the Mac app | Help → **Report a Bug or Request a Feature…** (⌘⌥F) or Settings → General → Feedback opens a sheet for a Bug or Feature request with a title, a description sent exactly as written, and up to six attachments (screenshots or documents via the file picker, drag and drop, or ⌘V). **Included details** shows the environment fields that accompany it; machine names, hostnames, and workspace labels are never included. This Mac's companion files the public GitHub issue through your authenticated `gh`, falling back to the first connected companion if needed, and hosts attachments as assets of a rolling `issue-attachments` release so images render inline. Leave **Start the automated fix pipeline** on to label the issue `herdr-autofix`. Requires a companion server advertising `issue-reports-v1`; older servers show an update message. |
| Code Factory automated fixes and releases | The optional `herdr-code-factory` daemon watches labeled issues from an allow-listed author, gives each one an isolated git worktree, has Astra plan and review, DeepSeek implement and revise in fresh Pi sessions, waits for green Verify CI, rebases conflicting branches (the rebase does not spend the review or CI budget), squash-merges, removes the worktree, then batches merged issues into a signed macOS preview release and closes them with the version. Transient provider failures retry automatically within a bound; repeated CI, review, and conflict failures stop at a bounded budget for a human. A Tailscale-bound dashboard tracks every issue's stage, PR, review round, released version, and worktree cleanup, with Retry, Skip, and Clean up actions. See [Code Factory](docs/code-factory.md) for setup, safety limits, and verification. |
| Independent components | Update the Mac app, iPhone app, or companion server separately when their API versions are compatible. Mac self-updates leave the server running. |
| Private local setup | Keep machine addresses, provider settings, and credentials outside Git while continuing to pull the shared source. A downloadable sample shows what to fill in. |
| Demo mode | Explore the native apps with synthetic data using `-HerdrDemoMode`, without connecting a real cluster. |

When adding or changing a user-facing feature, update this list and describe any
setup it needs. Release notes record what changed in a particular version.

See the [roadmap](ROADMAP.md) for deferred work and open product decisions,
including whether to improve or retire the standalone web companion.

## Start the server

Clone this repository, then run the commands below from your checkout.

Requirements: Python 3.11+, Node.js 22.19+, Git, and a running upstream Herdr
session. Install Pi to use agent chats. Native builds target macOS/iOS 26+
and have been verified with Xcode 26.2.

```sh
cd herdr-companion
python3.11 -m venv .venv
.venv/bin/python -m pip install -e '.[dev]'
npm --prefix frontend/herdr-web ci
npm --prefix frontend/herdr-web run build
.venv/bin/herdr-config init
.venv/bin/herdr-config check --machine desktop
.venv/bin/herdr-server --machine desktop
```

`herdr-config init` creates `~/.config/herdr-companion/config.toml` with owner-only file
permissions and a random API token. It never overwrites an existing file and
does not print the token. Open that file in your editor to customize it.

The default server listens on `127.0.0.1:9092`. Open
`http://127.0.0.1:9092/herdr-web/`, or connect a native app to that origin and
enter the API token from your private configuration. A token is required by
default. `--allow-insecure-local` is an explicit loopback-only development option.

Core Python code has no third-party runtime dependencies. The web build is
required for the browser client and Mac Git view. Build the web client before
making a Python release package; the wheel includes these assets and Pi extensions.

## One private configuration for your computers

[config.example.toml](config.example.toml) is the complete downloadable sample.
It contains fictional machines and commented provider examples. You can copy it
instead of using the initializer:

```sh
mkdir -p ~/.config/herdr-companion
cp config.example.toml ~/.config/herdr-companion/config.toml
chmod 600 ~/.config/herdr-companion/config.toml
```

Set a strong random `server.api_token` before starting the server. Keep the
filled-in file outside the repository. A checkout-local `config.local.toml`
is also supported and ignored by Git. The sample is the only configuration
file intended for publication.

The same private file can describe your complete cluster:

```toml
version = 1

[server]
host = "127.0.0.1"
port = 9092
state_dir = "~/.local/share/herdr-companion"

[machines.desktop]
name = "Desktop"
role = "local"
url = "https://desktop.example.invalid"
sidebar_label = "Build"
sidebar_order = 1

[machines.desktop.server]
api_token = { env = "DESKTOP_HERDR_TOKEN" }

[machines.laptop]
name = "Laptop"
role = "work"
url = "https://laptop.example.invalid"
sidebar_label = "Lab"
sidebar_order = 0

[machines.laptop.server]
api_token = { env = "LAPTOP_HERDR_TOKEN" }

[providers.transcription]
backend = "openai"
url = "https://speech.example.invalid/v1/audio/transcriptions"
model = "your-model"
token = { env = "SPEECH_API_KEY" }
```

Select the local machine explicitly on each computer:

```sh
herdr-server --config ~/.config/herdr-companion/config.toml --machine desktop
herdr-server --config ~/.config/herdr-companion/config.toml --machine laptop
```

Use different API tokens for individual machines. Secrets may live in the private
TOML, an environment variable (`{ env = "NAME" }`), or an existing owner-only
file (`{ file = "path" }`). Typed settings also accept an `_file` suffix, such as
`api_token_file`. Values are parsed as data, never shell code.

Configuration selection: `--config`, then `HERDR_CONFIG`, then
`./config.local.toml`, then `~/.config/herdr-companion/config.toml`. Machine selection:
`--machine`, then `HERDR_MACHINE`, then the file's top-level `machine` setting.
Explicit CLI arguments override process environment; environment overrides
per-machine settings; per-machine settings override shared settings. Each machine
can override shared tables. `[environment]` exposes additional Herdr settings
without a second configuration file.

Each machine may optionally set `sidebar_label` (trimmed, nonempty single-line
text up to 128 characters) and `sidebar_order` (an integer from 0 through
2,147,483,647). These values affect only the Mac sidebar's one-to-three-machine
segment bar. Explicit orders sort before machines without an order; ties and
unordered machines keep their roster order. Without a label, the complete
machine name remains visible. Names, roles, and IDs never imply a label or order.

The authenticated `/api/v1/config/machines` endpoint returns only allowlisted
machine names, IDs, roles, server origins, and those optional presentation
fields. When the server's selected machine exists uniquely in that roster, the
response also identifies that record with `localMachineId`; it is a public,
stable configured ID, not a credential. Native build configuration can seed this
same roster on first launch. API tokens are never included in the roster or
compiled into apps. Native connection credentials are stored in Keychain.

For an installed Mac app, the private TOML served by its **first saved
connection** is the sole sidebar-presentation authority. After editing that
file, restart that companion server, then use Refresh in the Mac app (or
reconnect/relaunch). The authenticated self ID lets the app apply that server's
presentation to the already-saved first connection even when it uses localhost
or another origin alias. It is used only for that primary connection and never
replaces a saved app ID or URL. Other already-paired machines still require
unique, exact HTTP(S) origin matches; the app does not add connections or match
names and roles. Duplicate or unknown self IDs are not guessed and fall back to
the same safe origin rules. Runtime synchronization requires both an updated
companion and an updated Mac app. A Mac-only app update does not install or
reconfigure companion servers. Older clients safely ignore the additive fields,
and a response from an older server without `localMachineId` keeps exact-origin
matching. If the roster endpoint is offline or unavailable, the Mac keeps its
last synchronized labels. A successful roster response with absent presentation
fields clears safely matched metadata and restores complete machine names and
default roster order; ambiguous matches retain cached presentation.

## Optional integrations

| Feature | Configuration / requirement |
| --- | --- |
| Git, file search, skills, uploads | Built into the server; Git must be installed for Git operations. |
| Pi chats and tools | Install Pi and configure its providers. Extensions are tested with Pi 0.84.2. |
| GitHub reviews | Authenticate `gh`; configure optional automation under `[integrations]`. |
| PR Review | Set `role = "development"` on the reviewing machine, authenticate `gh` there, install the review skills, and optionally tune `[pr_review]`; see [docs/pr-review.md](docs/pr-review.md). |
| Jira | Authenticate `acli` and configure your Jira site. No tenant or project is assumed. |
| Transcription | `[providers.transcription]` supports OpenAI-compatible and Parakeet services. |
| Summaries and quick voice | `[providers.summary]`, `[providers.voice]`, and `[providers.activity]`. |
| Spoken responses | Set a Kokoro/OpenAI-compatible endpoint under `[providers.tts]`. |
| Fleet catalogs | Configure a trusted `[fleet]` repository and additional skill destinations. |
| Active Work automation | Generic board API/CLI; Buzz sync and review polling are optional. |
| Issue reports and Code Factory | Authenticate `gh` and set the repository under `[code_factory]`; the daemon and dashboard are described in [docs/code-factory.md](docs/code-factory.md). |
| APNs and universal links | Configure `[push]` and `[apple]` with your own identity/domain. |
| Remote access | Configure your HTTPS origin. Tailscale Serve is optional. |

Unconfigured providers report unavailable capabilities and do not contact a
built-in private endpoint. Server and CLI entry points share the TOML. The
Pi package's [README](pi-semantic-bridge/README.md) covers handoff, notes, results, and on-demand Companion awareness. The offline `herdr-docs` CLI reads the same installed reference set without configuration or network.

For Pi started from your shell, apply the same machine configuration:

```sh
herdr-config exec --machine desktop -- pi
```

This passes the local API credentials and agent settings through the environment,
without printing credentials or including them in command arguments. Server-only
administration and remote-machine secrets are filtered out. Pi launched inside
Herdr discovers the running companion through an owner-only connection record
keyed to the terminal socket. This record is generated state, not another file
you need to configure.

For Tailscale, run `tailscale serve --bg --https=8461 9092`, then put your actual
HTTPS origin in the private roster. Set `HERDR_HARNESS_TAILSCALE_URL` under the
private `[environment]` table to advertise the configured route. Tailscale
access does not replace Herdr API authentication.

## Build the native apps

Open either `.xcodeproj` in Xcode, or build unsigned contributor versions:

```sh
xcodebuild -project herdr-harness-mac/herdr-harness-mac.xcodeproj \
  -scheme herdr-harness-mac -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project herdr-harness-ios/herdr-harness-ios.xcodeproj \
  -scheme herdr-harness-ios -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Both apps have demo mode (`-HerdrDemoMode`). For your signed builds, configure
`[apple]` in the same private TOML, then run:

```sh
.venv/bin/python herdr-harness-mac/Scripts/configure-apple.py \
  --config ~/.config/herdr-companion/config.toml --machine desktop
```

This generates ignored local Xcode settings, entitlements, and optional machine
bootstrap metadata. Keep these files and resulting private artifacts out of
public releases. Public releases must use neutral settings and synthetic demos.
Configure signing team, bundle IDs, Keychain identity, associated domains, and APNs
topic together. Existing installations may need private identity overrides or
re-pairing when these values change.

Direct Mac installations use the secure login Keychain by default and require no
App Store submission. See [Apple configuration](herdr-harness-mac/APPLE_CONFIGURATION.md)
for the optional Data Protection backend and the credential deployment probe.

## Mac app updates

Configured release builds check their signed GitHub Releases feed every four hours.
An available update appears in a banner: choose **Review update…**, then use
Sparkle's confirmation to install and relaunch. You can also choose **Herdr Companion →
Check for Updates…**. **Settings → Updates** controls automatic checks and optional preview
builds.

An available update appears both in the window's top bar — a version badge you can click at any time —
and in a banner at the top of the window: choose **Review update…**, then use Sparkle's confirmation
to install and relaunch. **Later** hides the banner while the top-bar badge stays until the update is
installed or superseded. Background checks run every ten minutes while Herdr is running (the first
one about two minutes after launch), and **Settings → Updates** shows the active channel and the last
and next check. Preview builds are included by default because every Herdr release is published on
the preview channel; turn the toggle off to stay on stable releases only. This updates the Mac app
independently of the companion server and uses no App Store submission. This updates the Mac app independently of the companion server and uses
no App Store submission.

Personal testing releases can use Apple Development signing without Developer ID
or notarization. Signed update verification stays enabled. These builds are
experimental and may need normal macOS approval on first installation.

See [macOS releases](docs/macos-releases.md) for signing modes, the
prepare/publish commands, and the first transition from a private app identity.
The release metadata and tooling do not imply that a public binary has been
published or that a signing certificate is configured.

## Update components independently

The Mac app and companion server can run different tested source revisions. Record
an installed revision and artifact hash for each component. Check the release's API
and state-format requirements before updating one side; independence does not make
arbitrary versions compatible.

For a **Mac-only update** of a configured release, use the app's update
controls described above. For a custom private build, generate Apple settings from
your existing private TOML, build and test the selected Mac revision, and install
its signed app bundle. Retain
the bundle and Keychain identities, back up the installed app and settings, and run
the [signed credential probe](herdr-harness-mac/APPLE_CONFIGURATION.md#verify-signed-credential-access-before-deployment)
on the destination. Keep the server runtime and its services running at their
current revision. Verify that the new app connects to that server before retiring
the previous app bundle.

For a **server-only update**, build the web assets and wheel from the selected
tested revision, install a new versioned runtime, and follow the
[server update procedure](herdr_harness/README.md#update-the-server).
Keep the installed native apps. Update the matching installed CLIs, Pi extension,
and any enabled background workers as part of the server change. Configuration-only
changes need validation and a restart of affected processes, not a new wheel.

Preserve the private TOML, credential files, and configured state locations during
both kinds of update. Keep the previous artifacts and service definitions for
rollback. Restore only the affected component unless compatibility requires a
matched pair; do not restore an older database over new user data without a
separate, consistent backup and a state migration plan.

## Development and verification

### First Mate feature workflows

Open **First Mate** in the Mac sidebar or iOS tab and create a feature with its
goal and project folder on the connected companion host. Each feature has one saved Pi
coordinator conversation. Workers run independently, return typed outcomes and
documents, and remain linked to their exact saved sessions. Every completed major
stage waits for your next plain-English direction. The timeline and graph show the
recorded workflow; Agents and Documents open the evidence behind each visit.
On Mac, use the **Chat / Git** control above the feature to open its full-width
Git workbench. The workspace picker defaults to the project checkout and lists
only exact worktrees recorded for that feature's assignments; see
[First Mate Git](docs/first-mate/git.md).

On Mac, **Companion host** starts at **All Machines**, showing features grouped by
host. Choose a specific host to filter the list; creating a feature from the
combined view still requires choosing its destination host. An explicit host
selection remains in effect until you change it.

The companion server runs the durable queue, execution watcher, bounded recovery,
and work log. Closing the Mac window does not stop the work. The optional browser
view is served at `/first-mate/` and uses the same authenticated API and records.
Coordinators, workers and internal advisors retain Pi's normal configured tools,
extensions, skills, prompt templates and project context in their assigned folder.
Coordinators keep direct work brief and delegate substantive work. A `read_only`
assignment is an instruction to leave the shared workspace unchanged, not a
separate security sandbox or tool capability boundary.
Configure Pi and optional Message Hub notifications in the private `[first_mate]`
section described in [config.example.toml](config.example.toml). No private
notification service or provider is enabled by a source-code default.

See the [runtime and operations guide](docs/first-mate/runtime.md),
[API contract](docs/first-mate/build-contract.md), and
[visual explainer](docs/first-mate/explainer/index.html). The
[iPhone and iPad guide](docs/first-mate/ios.md) covers mobile navigation and testing.

The native demo launch arguments `-HerdrDemoMode -HerdrFirstMateDemo` use entirely
synthetic records and never dispatch agents. On Mac, add `-HerdrFirstMateDark` to
start in dark mode. On iOS, use `-herdr.firstMate.appearance dark` or change the
appearance in First Mate options. This demo is for UI exploration and explainer
captures; real execution uses the active companion connection.

### Repository checks

```sh
.venv/bin/python -m unittest discover -s tests
npm --prefix pi-semantic-bridge ci
npm --prefix pi-semantic-bridge test
node --test tests/first_mate_web.test.cjs
npm --prefix frontend/herdr-web test
npm --prefix frontend/herdr-web run build
.venv/bin/python scripts/check-public-source.py
.venv/bin/python -m build
```

Enable the repository's private-source guard in your checkout:

```sh
git config core.hooksPath .githooks
```

CI also checks source, scans Git history for credentials, runs the Python/web/Pi
suites and native unit targets, and tests a wheel from an empty working directory.
To repeat the independent-install check locally:

```sh
python3.11 -m venv /tmp/herdr-wheel
/tmp/herdr-wheel/bin/python -m pip install dist/*.whl
.venv/bin/python scripts/verify-installed.py --python /tmp/herdr-wheel/bin/python
```

Run native unit and demo UI suites from Xcode on a suitable Mac/simulator.
Interactive tests need the OS permissions required by their test host. Test
servers use temporary loopback ports and state.

Before upgrading, take consistent backups. SQLite uses WAL: use its backup API
or stop writers and checkpoint, instead of copying a database while it is being
written. Preserve credentials, notes, jobs, artifacts, and board state privately.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Source is MIT licensed; included
third-party materials retain their licenses.

First Mate can also be driven through the authenticated `herdr-first-mate` CLI.
PR reviews are created, run, marked, ranked and opened through the authenticated `herdr-pr-review` CLI ([docs/pr-review.md](docs/pr-review.md)).
See [commands and native navigation](docs/first-mate/cli.md).
