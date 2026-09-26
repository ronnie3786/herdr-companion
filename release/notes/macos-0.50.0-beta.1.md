# Herdr Companion 0.50.0-beta.1

## Builds from Mobile App Hub

Herdr can now show installable iOS builds from a Mobile App Hub, a private web
app on your tailnet where agents publish builds.

- **First Mate Overview** has a **Builds** card under Pull requests. It lists the
  builds that First Mate's agents published, newest first, with ticket, feature,
  version, the Mac that built it, how old it is, and which assignment made it.
  Builds tag themselves with their First Mate when an agent publishes from a
  First Mate session, so the card fills in without extra steps.
- The **Dashboard** lists the newest builds of the apps you choose, below the
  First Mates. Search and Focus mode apply; Focus keeps builds from the last day.
- A green age marks a build from the last day, and an expired signing profile
  is flagged. Clicking a build opens its page in the hub, where you install it,
  browse the full history, and clean up old builds.

## Set it up

Open **Settings → General → Builds** and enter:

- **Mobile App Hub address**: the hub's full https:// address.
- **Dashboard apps**: the bundle IDs to feature on the Dashboard, separated by
  commas.

Both are saved on this Mac only. With no address, nothing about builds appears.
Herdr only reads the hub, refreshes once a minute while it is open, and keeps
the last list it loaded if the hub is unreachable.

## Compatibility and installation

Install this preview through **Herdr Companion → Check for Updates…**, with
**Include preview builds** enabled. The app is Apple Development-signed,
distributed through the signed update feed, and is not notarized.

This is a Mac app change only. It works with any companion version and needs no
server, Pi, or iOS update.

## Check the changes

- After setting the hub address, open a First Mate whose agents published a
  build. **Overview** shows the Builds card; click a build to open its hub page.
- With your app's bundle ID in **Dashboard apps**, the Dashboard shows its
  newest builds. Type a ticket number in Dashboard search to filter them.
