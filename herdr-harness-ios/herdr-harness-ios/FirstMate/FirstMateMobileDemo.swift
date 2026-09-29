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
    static func initialSnapshots(forMachineID machineID: String) -> [FirstMateSnapshot]? {
        guard machineID == "demo1" else { return nil }
        #if DEBUG
        if FirstMateTranscriptPerformanceProbe.enabled { return [transcriptPerformanceSnapshot()] }
        if FirstMateListPerformanceProbe.enabled { return performanceSnapshots() + [FirstMateDemo.chatWindowLead()] }
        #endif
        // Keep existing automation fixtures alongside the curated chat dataset;
        // their IDs remain valid through the list-to-detail transition.
        return FirstMateDemo.features(step: 0) + FirstMateDemo.chatWindowFeatures() + [FirstMateDemo.chatWindowLead()]
    }

    static func chatFleet(forMachineID machineID: String) -> [FirstMateFleetEntry] {
        guard machineID == "demo1" else { return [] }
        #if DEBUG
        if FirstMateListPerformanceProbe.enabled {
            return performanceSnapshots().enumerated().map { index, snapshot in
                .init(featureID: snapshot.feature.id, title: snapshot.feature.title, status: snapshot.feature.status,
                      hudStatus: index < 8 ? .blocked : .working, stepIndex: 1,
                      latestMessage: .init(id: "reply-\(index)", role: "assistant", text: "Synthetic update \(index). No agents launched.", createdAt: snapshot.feature.updatedAt),
                      latestFirstMateMessageID: "reply-\(index)", unread: index < 8, activityAt: snapshot.feature.updatedAt)
            }
        }
        #endif
        return FirstMateDemo.chatWindowFleet()
    }

    #if DEBUG
    static func transcriptPerformanceSnapshot() -> FirstMateSnapshot {
        var snapshot = FirstMateDemo.newFeature(title: "Transcript performance", goal: "Synthetic scrolling only.", cwd: "/workspace/synthetic", id: "demo-chat-performance")
        snapshot.messages = (0..<200).map { index in
            FirstMateMessage(id: "performance-message-\(index)", featureID: snapshot.feature.id,
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                text: "Message \(index). A complete synthetic turn; no agents launched.", status: "completed",
                createdAt: HerdrTimestamp.string(from: Date(timeIntervalSince1970: 1_900_000_000 + Double(index * 60))))
        }
        snapshot.messages[199].text += "\n\n" + (1...24).map { "Long paragraph \($0). Every sentence remains available while scrolling this synthetic message." }.joined(separator: "\n\n") + "\n\nEND OF COMPLETE MESSAGE"
        return snapshot
    }

    static func performanceSnapshots() -> [FirstMateSnapshot] { performanceFixture }

    private static let performanceFixture: [FirstMateSnapshot] = {
        let formatter = ISO8601DateFormatter()
        return (0..<100).map { index in
            let id = String(format: "performance-%03d", index)
            var feature = FirstMateDemo.newFeature(title: String(format: "Performance conversation %03d", index),
                goal: "A wholly synthetic scrolling fixture.", cwd: "/workspace/synthetic", id: id).feature
            feature.status = index < 8 ? "blocked" : "running"
            feature.updatedAt = formatter.string(from: Date(timeIntervalSince1970: 1_900_000_000 - Double(index)))
            return FirstMateSnapshot(feature: feature)
        }
    }()
    #endif

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
