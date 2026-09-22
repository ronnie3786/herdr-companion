# Herdr Companion 0.35.1-beta.3

## First Mate opens across your machines

- **Companion host** now defaults to **All Machines** when First Mate opens, showing features grouped by host instead of silently filtering to the first saved machine.
- Choosing an individual host still filters the list until you change the picker. Opening a feature from the combined list keeps its actual host and does not route actions to another machine. Creating a feature from the combined list still asks for a destination host.

Open **First Mate** in the Mac sidebar to see the combined list. Use **Companion host** to filter to one machine or return to **All Machines**.

## Compatibility

This is a Mac-only preference change using the existing First Mate fleet APIs. Keep existing companion servers on both machines; no server package, restart, or migration is needed. Hosts without First Mate support report their own availability in the combined list.

This preview is signed for personal testing and is not notarized. Install it through the existing signed updater with **Include preview builds** enabled.
