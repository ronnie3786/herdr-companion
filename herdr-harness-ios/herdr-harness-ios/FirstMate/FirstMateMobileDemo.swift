import Foundation

/// iOS-local additions to the shared synthetic First Mate demo.
///
/// The shared `HerdrFirstMateShared` demo is shared with the Mac app and is not
/// changed here. The mobile fleet has more than one demo host, so this file adds
/// one entirely synthetic, host-owned feature to the second host. That gives the
/// combined All Machines list a duplicate feature ID on two hosts (the shared
/// demo features) plus a genuinely host-specific row, without live agents and
/// without touching the shared Mac demo.
enum FirstMateMobileDemo {
    /// Extra synthetic snapshots owned by one demo host. Nothing is fetched,
    /// nothing leaves the device, and every value is invented.
    static func supplementalSnapshots(forMachineID machineID: String) -> [FirstMateSnapshot] {
        guard machineID == "demo2" else { return [] }
        let featureID = "demo2-release-checklist"
        let visitID = "demo2-verify"
        let feature = FirstMateFeature(
            id: featureID,
            title: "Ship the release checklist",
            goal: "Keep signing, notarization, and rollback steps together on the laptop.",
            cwd: "/workspace/release-tools",
            status: "awaiting_direction",
            currentVisitID: visitID,
            revision: 1,
            createdAt: FirstMateDemo.timestamp,
            updatedAt: FirstMateDemo.timestamp,
            workItemID: "DEMO-207"
        )
        let visit = FirstMateVisit(
            id: visitID,
            featureID: featureID,
            stageKey: "proof",
            title: "Proof",
            status: "awaiting_direction",
            revision: 1,
            createdAt: FirstMateDemo.timestamp
        )
        let message = FirstMateMessage(
            id: "demo2-release-welcome",
            featureID: featureID,
            role: "assistant",
            text: "The release checklist is drafted. Confirm the signing order before the laptop continues.\n\nSynthetic demo. No model or repository changes were executed.",
            status: "delivered",
            createdAt: FirstMateDemo.timestamp
        )
        return [FirstMateSnapshot(feature: feature, visits: [visit], messages: [message])]
    }
}
