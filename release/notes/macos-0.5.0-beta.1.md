# Herdr for Mac 0.5.0-beta.1

- HUD session bubbles show cumulative Pi cost at the bottom right, refreshing every 15 seconds. Audio controls move to the top right so they cannot cover it. Before Pi reports a cost, the bubble shows “Cost …”; temporary connection failures retain the last known total for that session.
- See the connected machine alongside workspace and path in the Chat header.
- Click the Chat title to edit it inline. Enter or clicking outside saves; Escape cancels. Empty and unchanged titles leave the existing name intact.
- Right-click a sidebar Pi chat, HUD session bubble, or its Chat header and choose **Smart Rename**. The pane actions menu includes it too. A separate headless Pi run reads the original goal and recent conversation and applies a short contextual title. Your active Pi session continues undisturbed.
- Smart Rename uses the configured Quick Chat model (or the companion's default) with low thinking and a 60-second generation limit. It requires conversation access and the existing headless agent API. Unavailable conversations and invalid AI responses leave the name intact, as do title or session changes while generation is underway.

No companion server upgrade or iOS update is required. This preview uses the existing API contract and signed Mac update feed.
