# Mac Dashboard and Agent view

The Mac app opens on Dashboard. It uses the existing purple Herdr theme and has
three sections: active First Mates across connected machines, PR Reviews, and the
same 20 recent chats as the sidebar. First Mate cards are ordered by requests for
direction, blocked work, working features, then paused/ready work. Completed,
cancelled, and archived features are excluded. The lower sections stack when the
available content width is narrow. No decorative motion is used.

**Focus mode** is shared between Dashboard and Agent view and persists on this Mac.
It shows only work waiting on the user: First Mates awaiting direction or blocked. Reviews remain
visible for pending drafts and re-review requests. Recent chats remain visible only
when they need input. Unknown, paused, completed, and merely unread states do not
create attention. The setting changes visibility, never work execution.

First Mate cards open their owning machine and feature with Overview selected.
Section headings open the existing First Mate, PR Review, and Chat screens. Agent
view opens independent 380-point columns with Chat, Overview, Agents, and Workflow
tabs. Each column retains its tab and unfinished reply when filtered out or when
visiting another screen. Replies target that column's owning host and feature;
failed requests retain their retry identity and draft. Only visible columns poll
full snapshots while the app is active. A changed host identity invalidates old
requests. Agent/session links use the matching live pane where available and saved
history otherwise. Documents and administration remain in the full First Mate view.

Use the Dashboard toolbar button, sidebar entry, or **Navigate → Dashboard**
(Shift-Command-D) to return home. The new destinations participate in Back/Forward
history. Existing deep links still open their requested destinations.

The recent-chat machine filter is independent of the sidebar machine selection and
persists on this Mac. Agent column tab choices are kept for this app session.

## Companion compatibility

The Mac can connect to older companions. Missing summary fields show an honest
fallback; unavailable GitHub state is never labeled “Not reviewed.” Offline hosts
keep their last known work and last-seen indication. The card stage total is only
shown when a complete total is known; the current server records visited stages,
so its cards show “Stage N.”

[Dashboard API](dashboard-api.md) describes the additive companion fields and cached
GitHub review-state worker. The Dashboard polls cached PR summaries every ten seconds
while active and requests GitHub refresh once per minute, on activation, and manually.
Failed refreshes retain the last successful timestamp. Only active reviews already
in the PR Review workspace are included; known self-authored PRs are excluded.
A separately installed companion update is required for live review states and
lightweight card summaries. Building or releasing the Mac app does not deploy it.

## Verification

Use the README's native build/test command, selecting DashboardTests,
AgentBoardStateTests, DashboardRenderTests, PRReviewStoreTests, and the navigation
history suites for focused coverage. Render fixtures are entirely synthetic.
HerdrDashboardUITests covers home navigation and shared Focus mode in demo mode.
