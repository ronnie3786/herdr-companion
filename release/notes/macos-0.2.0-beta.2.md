# Herdr 0.2.0-beta.2

The floating HUD's X button is half its previous visual size and sits slightly
higher. Its pointer target and accessible Hide HUD label are preserved.

This preview also includes contextual question conversations in the HUD and
Notes, with an explicit handoff to an agent for actions. These conversations
require a companion server with the contextual-question-v1 profile. The app
update does not update the server.

For an existing release installation, enable **Include preview builds** in
**Settings → App updates**, then choose **Check for Updates…**. After installing,
show the HUD to inspect its smaller X button.

Private builds with a different application identity require a one-time migration
to the release app before they can receive updates through this feed. Preserve
settings and verify machine credentials during that migration.
