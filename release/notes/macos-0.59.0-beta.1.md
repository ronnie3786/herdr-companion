# macOS 0.59.0-beta.1

## First Mate lives on this Mac

**My First Mate** and the HUD's chat now talk to the First Mate on this Mac's own companion instead of the machine with the most features. It reaches your other machines itself, so one machine going down never takes First Mate with it.

- **One First Mate across your machines.** "What needs me?" covers this Mac and every other machine its companion can reach, and a decision for a feature on another machine is passed on the same way as one here. First Mate names the machine when it matters.
- **A machine goes down, the rest keep working.** When another machine stops answering, First Mate says it is offline and keeps helping with everything else. Your features here never depend on it.
- **This Mac's companion goes down.** After two missed checks, the chat window and the HUD talk to another machine's First Mate instead and say which machine is offline. They move back once this Mac's companion answers again.
- **Choose where it runs.** The machine menu in the First Mate chat window's header now has **Automatic** (this Mac's machine) and your other machines. A choice stays until you pick Automatic again.

Machines First Mate cannot reach itself (for example, a companion without that machine's credential) still come along as a read-only summary with each message, now marked offline when this Mac cannot reach them either.

## Compatibility and installation

Reaching other machines needs companion **0.59.0b1** or newer on this Mac and on each machine it reaches (`first-mate-lead-peers-v1`). This Mac's companion reaches the machines whose API credential is configured in its private configuration, the same ones `herdr-control --machine` reaches. Until this Mac's companion is updated, First Mate stays where it is today, so installing the app first changes nothing.

Install this preview through **Settings → Updates → Check for Updates…**, with **Include preview builds** enabled. The app is Apple Development-signed, distributed through the signed update feed, and is not notarized. The Mac updater installs only the app; update each companion separately.

## Check the changes

- Open **My First Mate** and ask "What needs me?". Expect features from this Mac and your other machines, each named with its machine where that helps.
- Tell First Mate a decision for a feature on another machine. Expect your words in that feature's chat.
- Open the machine menu in the chat window's header. Expect **Automatic** checked, naming this Mac's machine.
