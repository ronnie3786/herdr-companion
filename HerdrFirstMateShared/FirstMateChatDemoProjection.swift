import Foundation

/// Shared projection of synthetic fleet entries and locally updated snapshots.
enum FirstMateChatDemoProjection {
    static func host(fleet: [FirstMateFleetEntry], snapshots: [String: FirstMateSnapshot], lastUpdated: Date,
                     machineID: String, machineName: String) -> FirstMateFleetHost {
        var entries: [String: FirstMateFleetEntry] = [:]
        for var entry in fleet {
            if let feature = snapshots[entry.featureID]?.feature { entry.archivedAt = feature.archivedAt }
            if let snapshot = snapshots[entry.featureID],
               let latest = snapshot.messages.last(where: \.isConversation),
               latest.id != entry.latestMessage?.id {
                entry.latestMessage = FirstMateFleetLatestMessage(
                    id: latest.id, role: latest.role, text: String(latest.text.prefix(200)), createdAt: latest.createdAt
                )
                if latest.createdAt > (entry.activityAt ?? "") { entry.activityAt = latest.createdAt }
                if latest.role == "assistant", latest.id != entry.latestFirstMateMessageID {
                    entry.latestFirstMateMessageID = latest.id
                    entry.unread = true
                }
            }
            entries[entry.featureID] = entry
        }
        let features = fleet.compactMap { snapshots[$0.featureID]?.feature }
        return FirstMateFleetHost(
            machineID: machineID,
            machineName: machineName,
            features: features,
            isLoading: false,
            error: nil,
            unsupported: false,
            lastUpdated: lastUpdated,
            supportsFleet: true,
            fleetEntries: entries
        )
    }
}
